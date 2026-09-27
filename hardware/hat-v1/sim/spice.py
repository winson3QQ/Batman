"""Minimal ctypes wrapper around libngspice (ships with KiCad) -- no extra installs."""
import ctypes
import ctypes.util

_lib = ctypes.CDLL(ctypes.util.find_library("ngspice") or "libngspice.so.0")


class _Cplx(ctypes.Structure):
    _fields_ = [("re", ctypes.c_double), ("im", ctypes.c_double)]


class _VecInfo(ctypes.Structure):
    _fields_ = [("vname", ctypes.c_char_p), ("type", ctypes.c_int), ("flags", ctypes.c_short),
                ("realdata", ctypes.POINTER(ctypes.c_double)), ("compdata", ctypes.POINTER(_Cplx)),
                ("length", ctypes.c_int)]


_SendChar = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p)
_SendStat = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p)
_Exit = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.c_bool, ctypes.c_bool, ctypes.c_int, ctypes.c_void_p)
LOG = []
_cb = (_SendChar(lambda s, i, p: LOG.append(s.decode(errors="replace")) or 0),
       _SendStat(lambda s, i, p: 0),
       _Exit(lambda st, unl, q, i, p: 0))
_lib.ngSpice_Init(_cb[0], _cb[1], _cb[2], None, None, None, None)
_lib.ngGet_Vec_Info.restype = ctypes.POINTER(_VecInfo)


def cmd(c):
    _lib.ngSpice_Command(c.encode())


def run(netlist, analysis):
    """Load a netlist (string, without .end), run one analysis command, return the plot name."""
    LOG.clear()
    cmd("destroy all")
    lines = [l for l in netlist.strip().splitlines()] + [".end"]
    arr = (ctypes.c_char_p * (len(lines) + 1))(*[l.encode() for l in lines], None)
    _lib.ngSpice_Circ(arr)
    cmd(analysis)
    if any("error" in l.lower() and "no error" not in l.lower() for l in LOG):
        raise RuntimeError("\n".join(LOG[-20:]))


def vec(name):
    p = _lib.ngGet_Vec_Info(name.encode())
    if not p:
        raise KeyError(name)
    v = p.contents
    if v.realdata:
        return [v.realdata[i] for i in range(v.length)]
    return [complex(v.compdata[i].re, v.compdata[i].im) for i in range(v.length)]
