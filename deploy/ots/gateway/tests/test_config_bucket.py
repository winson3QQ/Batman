import pytest

from batman_eud_gateway import config
from batman_eud_gateway.bucket import TokenBucket


def test_defaults_match_design():
    s = config.load({})
    assert (s.max_devices, s.max_devices_per_user, s.max_conns_per_device, s.max_pending) == (64, 4, 3, 1024)
    assert (s.ident_max_s, s.ident_hard_s, s.supersede_quiet_s, s.supersede_max_s) == (60, 120, 20, 120)
    assert s.max_event_bytes == 65536 and s.max_carry_bytes == 1048576
    assert not s.tcp_enabled


def test_malformed_int_is_config_error():
    with pytest.raises(config.ConfigError):
        config.load({"GATEWAY_MAX_DEVICES": "sixty-four"})
    with pytest.raises(config.ConfigError):
        config.load({"GATEWAY_RESERVE_MB": "-1"})


def test_relations_enforced():
    with pytest.raises(config.ConfigError):
        config.load({"GATEWAY_MAX_EVENT_BYTES": "2000000"})   # > carry bound
    with pytest.raises(config.ConfigError):
        config.load({"GATEWAY_SUPERSEDE_QUIET_S": "200"})     # > max


def test_allowlist_name_guard_and_dupes():
    s = config.load({"GATEWAY_8088_ALLOWLIST": " relay-1 , relay-2 "})
    assert s.allowlist_8088 == ("relay-1", "relay-2") and s.tcp_enabled
    for bad in ("cot_parser", "amq.direct", "AMQ.x", "a\x00b", "x" * 300):
        with pytest.raises(config.ConfigError):
            config.load({"GATEWAY_8088_ALLOWLIST": bad})
    with pytest.raises(config.ConfigError):
        config.load({"GATEWAY_8088_ALLOWLIST": "r1,r1"})


def test_name_ok():
    assert config.name_ok("ANDROID-abc123")
    assert config.name_ok("小明") is True
    assert not config.name_ok("")
    assert not config.name_ok("dms")
    assert not config.name_ok("firehose")
    assert not config.name_ok("x\ny")


def test_bucket_take_and_refill():
    b = TokenBucket(rate=10, burst=5, now=0.0)
    assert all(b.take(1, now=0.0) for _ in range(5))
    assert not b.take(1, now=0.0)
    assert b.take(1, now=0.1)          # refilled 1 token
    assert not b.take(1, now=0.1)


def test_bucket_charge_backpressure():
    b = TokenBucket(rate=100, burst=100, now=0.0)
    assert b.charge(100, now=0.0) == 0.0
    wait = b.charge(50, now=0.0)
    assert abs(wait - 0.5) < 1e-9
    assert b.charge(0, now=0.5) == 0.0
