"""batman_eud_gateway — the OTS EUD gateway (#289, docs/design/289-eud-gateway.md).

One asyncio process in the OTS image replacing ots_eud_handler / ots_eud_handler_ssl and the #264
overlay: sessions keyed by DEVICE, store-before-route, one AMQP connection with publisher confirms,
one consumer per device, bounded non-blocking downlink, presence and bindings owned here.
Mechanisms are numbered M1–M18 as in the design; every module names the ones it implements.
"""

__version__ = "0.1.0"
