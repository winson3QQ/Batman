// #329 design §4.6: the CBOR subset of `ui/state-v1` — unsigned ints, booleans, text strings and maps, nothing else.
// The decoder is strict: any other type, a truncated or over-long item, trailing bytes or nesting deeper than 4 is a
// FormatException (UiState then treats the record as absent).
import 'dart:convert';
import 'dart:typed_data';

Uint8List cborEncode(Object v) {
  final b = BytesBuilder();
  void head(int major, int n) {
    if (n < 24) {
      b.addByte(major << 5 | n);
    } else if (n < 0x100) {
      b.add([major << 5 | 24, n]);
    } else if (n < 0x10000) {
      b.add([major << 5 | 25, n >> 8, n & 0xff]);
    } else if (n < 0x100000000) {
      b.add([major << 5 | 26, n >> 24 & 0xff, n >> 16 & 0xff, n >> 8 & 0xff, n & 0xff]);
    } else {
      b.addByte(major << 5 | 27);
      for (var s = 56; s >= 0; s -= 8) {
        b.addByte(n >> s & 0xff);
      }
    }
  }

  void item(Object v) {
    switch (v) {
      case final bool x:
        b.addByte(x ? 0xf5 : 0xf4);
      case final int x when x >= 0:
        head(0, x);
      case final String x:
        final u = utf8.encode(x);
        head(3, u.length);
        b.add(u);
      case final Map<Object, Object> x:
        head(5, x.length);
        x.forEach((k, v) {
          item(k);
          item(v);
        });
      default:
        throw ArgumentError('not in the ui/state-v1 subset: ${v.runtimeType}');
    }
  }

  item(v);
  return b.toBytes();
}

Object cborDecode(Uint8List data) {
  var i = 0;
  int byte() {
    if (i >= data.length) throw const FormatException('truncated');
    return data[i++];
  }

  int arg(int info) {
    if (info < 24) return info;
    final n = switch (info) { 24 => 1, 25 => 2, 26 => 4, 27 => 8, _ => throw const FormatException('bad length') };
    var v = 0;
    for (var k = 0; k < n; k++) {
      v = v << 8 | byte();
    }
    if (v < 0) throw const FormatException('too large');
    return v;
  }

  Object item(int depth) {
    if (depth > 4) throw const FormatException('too deep');
    final h = byte();
    final major = h >> 5, info = h & 0x1f;
    switch (major) {
      case 0:
        return arg(info);
      case 3:
        final n = arg(info);
        if (n > data.length - i) throw const FormatException('truncated text');
        final s = utf8.decode(data.sublist(i, i + n));
        i += n;
        return s;
      case 5:
        final n = arg(info);
        if (n > data.length - i) throw const FormatException('truncated map');
        final m = <Object, Object>{};
        for (var k = 0; k < n; k++) {
          final key = item(depth + 1);
          if (m.containsKey(key)) throw const FormatException('duplicate key');
          m[key] = item(depth + 1);
        }
        return m;
      case 7 when info == 20 || info == 21:
        return info == 21;
      default:
        throw FormatException('type $major/$info is not in the subset');
    }
  }

  final v = item(0);
  if (i != data.length) throw const FormatException('trailing bytes');
  return v;
}
