# SPI diagnostic scripts

Small `spidev`-based scripts used to characterise the MM6108's SPI behaviour without
the kernel driver in the way. They were what turned an opaque `-71` into a precise
"the response is two bits late" — see [`../docs/root-cause.md`](../docs/root-cause.md).

Requires `python3-spidev`.

## Detach the driver first

```sh
sudo modprobe spidev
echo spidev | sudo tee /sys/bus/spi/devices/spi0.0/driver_override
echo spi0.0 | sudo tee /sys/bus/spi/drivers/spidev/bind
```

## Run

| Script | What it does |
|---|---|
| `driver_replica.py` | Sends byte-for-byte what `morse_spi_cmd()` sends, and decodes the response the same way `morse_spi_find_response()` does. **Start here.** |
| `cmd63.py` | Raw SD/SDIO-over-SPI commands (CMD63 / CMD0 / CMD52 / CMD5) with correct CRC7 |
| `spitest.py` | Sweeps 1/4/10/50 MHz with several TX patterns — use this to separate signal-integrity problems from logic problems |
| `modetest.py` | Tries all four SPI modes (CPOL/CPHA combinations) |
| `misotest.py` | Minimal check that MISO is actually being driven by the slave |

## Restore the driver afterwards

```sh
echo spi0.0 | sudo tee /sys/bus/spi/drivers/spidev/unbind
echo ""     | sudo tee /sys/bus/spi/devices/spi0.0/driver_override
sudo pinctrl set 9 a0 pu
echo spi0.0 | sudo tee /sys/bus/spi/drivers/morse_spi/bind
```

## Reference result

On the hardware described in [`../docs/hardware.md`](../docs/hardware.md), before the
`SPI_NO_CS` patch:

- first non-`0xFF` response byte is `0xC0` — the correct `0x00`, two bit-times late
- identical at every clock rate tested
- `CMD5`, shifted left two bits, decodes as a valid SDIO R4: `R1=0x00`, `OCR=0xA0FF8000`

i.e. the chip is alive and correct; only the bit phase is wrong.
