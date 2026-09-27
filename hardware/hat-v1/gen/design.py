"""Batman HAT v1 -- single source of truth for the schematic.

Every part, value and connection lives here. gen_sch.py turns it into
KiCad 7 schematics, check.py re-reads KiCad's own netlist export and
verifies it against this file and against docs/design/hat-v1-spec.md.

Conventions
  * Net names are Pi-centric: UART5_TX = GPIO12 (Pi transmits).
  * None as a pin's net = intentionally not connected (gets a no-connect flag).
  * tier: A = trust chain (not assembled by JLC, fitted in Taiwan),
          B = logic, no firmware, C = passive / discrete  (spec section 5.8).
  * dnp=True = footprint only, not fitted by default (tuning / options).
"""
from dataclasses import dataclass, field

PROJECT = "batman-hat"
TITLE = "Batman HAT v1 (Pi 4) - replaces Seeed WM1302 HAT"
REV = "0.1-draft"
DATE = "2026-09-27"


@dataclass
class Part:
    ref: str
    sym: str
    value: str
    pins: dict
    sheet: str
    fp: str = ""
    mpn: str = ""
    mfr: str = ""
    tier: str = "C"
    dnp: bool = False
    note: str = ""
    lcsc: str = ""


PARTS: list = []
SHEETS = [
    # (file stem, title shown on the sheet)
    ("power_in", "1 Power input: TVS, eFuse, reverse protection, system current"),
    ("power_5v", "2 5 V buck for the Pi + ideal-diode (HAT back-power rule)"),
    ("power_3v3", "3 3.3 V for HaLow: source OR-ing, FCCM buck, HaLow current"),
    ("softpower", "4 Soft power: LTC2955-2 push-button / AUTO-ON / KILL"),
    ("pi_header", "5 Pi 40-pin header, HAT ID EEPROM, mounting"),
    ("halow", "6 mPCIe socket for Wio-WM6108 (pinout unchanged)"),
    ("security", "7 TPM 2.0 SLB9672, ATECC608C, RTC RV-3028"),
    ("gnss", "8 GNSS MAX-M10S + active antenna bias"),
    ("debug", "9 Debug: Tag-Connect, test points, LEDs, power flags"),
]
_sheet = [None]


def sheet(name):
    assert name in [s for s, _ in SHEETS], name
    _sheet[0] = name


def part(ref, sym, value, pins, **kw):
    assert all(p.ref != ref for p in PARTS), f"duplicate ref {ref}"
    PARTS.append(Part(ref, sym, value, {str(k): v for k, v in pins.items()}, _sheet[0], **kw))


_R_FP = {s: f"Resistor_SMD:R_{s}_{m}Metric" for s, m in
         [("0402", "1005"), ("0603", "1608"), ("0805", "2012"), ("1206", "3216"), ("2512", "6332")]}
_C_FP = {s: f"Capacitor_SMD:C_{s}_{m}Metric" for s, m in
         [("0402", "1005"), ("0603", "1608"), ("0805", "2012"), ("1206", "3216"), ("1210", "3225")]}


def R(ref, value, a, b, size="0402", **kw):
    part(ref, "R", value, {1: a, 2: b}, fp=_R_FP[size], **kw)


def C(ref, value, a, b, size="0402", **kw):
    part(ref, "C", value, {1: a, 2: b}, fp=_C_FP[size], **kw)


def NMOS_SOT23(ref, g, d, s, value="BSS138", **kw):
    # SOT-23: 1 = G, 2 = S, 3 = D
    kw.setdefault("mpn", "BSS138")
    kw.setdefault("mfr", "onsemi (not Nexperia)")
    part(ref, "NMOS", value, {1: g, 2: s, 3: d}, fp="Package_TO_SOT_SMD:SOT-23", **kw)


def NMOS_Q3(ref, g, d, s, value, **kw):
    # TI NexFET SON 3.3x3.3: 1-3 = S, 4 = G, drain pins + pad merged into pad 5 (stock footprint)
    part(ref, "NMOS_SON8", value,
         {1: s, 2: s, 3: s, 4: g, 5: d},
         fp="Package_SON:VSON-8_3.3x3.3mm_P0.65mm_NexFET", mfr="TI", tier="C", **kw)


def footprint_only(p):
    """Copper only, nothing to buy or place: excluded from BOM / JLC files."""
    return ((p.sym in ("SJ", "MH", "PWR_FLAG") and not p.mpn) or p.ref in ("J1", "J5")
            or p.fp.startswith("TestPoint:TestPoint_Pad"))


def TP(ref, net, value, big=False, **kw):
    fp = ("TestPoint:TestPoint_Keystone_5015_Micro-Minature" if big
          else "TestPoint:TestPoint_Pad_D1.0mm")
    part(ref, "TP", value, {1: net}, fp=fp, **kw)


def SJ(ref, a, b, closed, value, **kw):
    fp = ("Jumper:SolderJumper-2_P1.3mm_Bridged_RoundedPad1.0x1.5mm" if closed
          else "Jumper:SolderJumper-2_P1.3mm_Open_RoundedPad1.0x1.5mm")
    part(ref, "SJ", value + (" (closed)" if closed else " (open)"), {1: a, 2: b}, fp=fp, **kw)


# ---------------------------------------------------------------------------
# Sheet 1 -- power input
# ---------------------------------------------------------------------------
sheet("power_in")
part("J1", "CONN2", "BATT pads", {1: "VBAT_RAW", 2: "GND"},
     fp="batman:BattPads_2x_3x5mm_StrainRelief",
     note="battery / 12 V adapter wires soldered directly, zip-tie holes; 6-17 V")
part("D1", "TVS_BI", "SMBJ20CA", {1: "VBAT_RAW", 2: "GND"}, fp="Diode_SMD:D_SMB",
     mpn="SMBJ20CA", mfr="Littelfuse", note="bidirectional: survives reversed battery")
C("C1", "1u 50V X7R", "VBAT_RAW", "GND", "0805")
C("C2", "100n 50V X7R", "VBAT_RAW", "GND", "0402")
R("R19", "1R", "VBAT_RAW", "VBAT_DAMP", "0805", note="RC damper: tames hot-plug ringing of the battery leads")
C("C8", "10u 50V X7R", "VBAT_DAMP", "GND", "1210")
NMOS_Q3("Q1", "EF_BGATE", "EF_IN", "VBAT_RAW", "CSD19537Q3", mpn="CSD19537Q3",
        note="reverse-polarity blocking FET (TPS2663 datasheet Fig 9-2)")
NMOS_SOT23("Q2", "EF_DRV", "EF_BGATE", "VBAT_RAW",
           note="B_GATE fast pull-down: Vds>=15V, Vgs max 20V, Ciss<=50pF, Vth(min)<=3V")
part("U1", "TPS26631RGE", "TPS26631RGER", {
    1: "EF_IN", 2: "EF_IN", 3: "EF_BGATE", 4: "EF_DRV", 5: "VBAT_RAW", 6: "EF_UVLO",
    7: "EF_OVP", 8: "GND", 9: "EF_DVDT", 10: "EF_ILIM", 11: "GND", 12: "EF_SHDN",
    13: None, 14: "EF_FLT_N", 15: "EF_PGTH", 16: "EN_5V", 17: "EF_OUT", 18: "EF_OUT",
    25: "GND"},
    fp="Package_DFN_QFN:Texas_RGE0024H_VQFN-24-1EP_4x4mm_P0.5mm_EP2.7x2.7mm_ThermalVias",
    mpn="TPS26631RGER", mfr="TI", tier="B",
    note="MODE=GND auto-retry; SHDN floats (2.7 V open-circuit) = enabled; IMON unused")
R("R1", "383k 1%", "VBAT_RAW", "EF_UVLO")
R("R2", "100k 1%", "EF_UVLO", "GND")
R("R3", "1.50M 1%", "VBAT_RAW", "EF_OVP",
  note="OVP 19.2 V typ (18.8-19.6), release >=17.44 V: full 4S 16.8 V never latches off (review P3)")
R("R4", "100k 1%", "EF_OVP", "GND")
R("R5", "3.57k 1%", "EF_ILIM", "GND", note="I_OL = 18k/R = 5.0 A")
C("C3", "22n 16V X7R", "EF_DVDT", "GND", note="2.27 V/ms soft start")
R("R6", "383k 1%", "EF_OUT", "EF_PGTH")
R("R7", "100k 1%", "EF_PGTH", "GND")
C("C4", "1u 50V X7R", "EF_OUT", "GND", "0805")
C("C9", "100n 50V X7R", "EF_IN", "GND", note="IN pins need >=0.1 uF (TPS2663 rec. operating)")
R("R8", "4.7k", "EF_IN", "LED_FLT_A", "0603", note="LED fed from EF_IN: protected from reverse battery")
part("D2", "LED", "RED", {1: "EF_FLT_N", 2: "LED_FLT_A"}, fp="LED_SMD:LED_0402_1005Metric",
     note="eFuse fault LED (on = fault)")
R("R9", "10m 1% 0.5W", "EF_OUT", "VSYS", "1206",
  note="INA226 #1 shunt; route IN+/IN- as Kelvin traces from the pads")
part("U2", "INA226", "INA226AIDGSR", {
    1: "GND", 2: "GND", 3: "INA_ALERT_N", 4: "I2C1_SDA", 5: "I2C1_SCL", 6: "3V3_PI",
    7: "GND", 8: "VSYS", 9: "VSYS", 10: "EF_OUT"},
    fp="Package_SO:VSSOP-10_3x3mm_P0.5mm", mpn="INA226AIDGSR", mfr="TI", tier="B",
    note="I2C 0x40 (A0=A1=GND): whole-node current + battery voltage")
C("C5", "100n 16V", "3V3_PI", "GND")
C("C6", "10u 50V X7R", "VSYS", "GND", "1210")
C("C7", "10u 50V X7R", "VSYS", "GND", "1210")
# battery present -> GPIO4 (low = battery / adapter connected)
R("R10", "1M", "VBAT_RAW", "BATP_G", note="1M/1M: 9 uA standby drain")
R("R11", "1M", "BATP_G", "GND")
NMOS_SOT23("Q6", "BATP_G", "BAT_PRESENT_N", "GND")
R("R12", "10k", "BAT_PRESENT_N", "3V3_PI")

# ---------------------------------------------------------------------------
# Sheet 2 -- 5 V buck + ideal diode to the Pi
# ---------------------------------------------------------------------------
sheet("power_5v")
part("U3", "LMR33640", "LMR33640DDDAR", {
    1: "GND", 2: "VSYS", 3: "EN_5V", 4: "PG_5V", 5: "FB_5V", 6: "VCC_5V", 7: "BOOT_5V",
    8: "SW_5V", 9: "GND"},
    fp="Package_SO:Texas_HSOP-8-1EP_3.9x4.9mm_P1.27mm_ThermalVias",
    mpn="LMR33640DDDAR", mfr="TI", tier="B", note="1 MHz, 4 A")
C("C10", "10u 50V X7R", "VSYS", "GND", "1210")
C("C11", "220n 50V X7R", "VSYS", "GND", "0603", note="hot-loop cap: closest to VIN/PGND")
C("C12", "100n 16V", "BOOT_5V", "SW_5V")
C("C13", "1u 10V", "VCC_5V", "GND")
part("L1", "L", "3.3uH Isat>=5.5A", {1: "SW_5V", 2: "5V_BUCK"},
     fp="Inductor_SMD:L_Coilcraft_XxL4030", mpn="XGL4030-332MEC", mfr="Coilcraft",
     note="height <=3.1 mm; alternative: Wurth WE-XHMI 4030")
C("C14", "22u 10V X5R", "5V_BUCK", "GND", "0805")
C("C15", "22u 10V X5R", "5V_BUCK", "GND", "0805")
C("C16", "22u 10V X5R", "5V_BUCK", "GND", "0805")
R("R13", "100k 0.5%", "5V_BUCK", "FB_5V")
R("R14", "24.0k 0.5%", "FB_5V", "GND", note="Vout = 1.0 V x (1 + 100/24) = 5.17 V")
C("C17", "DNP 22p", "5V_BUCK", "FB_5V", dnp=True, note="optional feed-forward (datasheet 9.2.2.8)")
R("R15", "102k 1%", "VSYS", "EN_5V")
R("R16", "24.3k 1%", "EN_5V", "GND", note="EN UVLO: 6.40 V on / 5.88 V off")
NMOS_SOT23("Q7", "LTC_ENB", "EN_5V", "GND", note="LTC2955 EN-bar high (off) -> 5 V buck off")
R("R17", "100k", "PG_5V", "VCC_5V")
part("U4", "LM74700", "LM74700QDBVRQ1", {
    1: "VCAP_5V", 2: "GND", 3: "5V_BUCK", 4: "5V_PI", 5: "G_5VID", 6: "5V_BUCK"},
    fp="Package_TO_SOT_SMD:SOT-23-6", mpn="LM74700QDBVRQ1", mfr="TI", tier="B",
    note="HAT back-power rule: Pi USB-C cannot feed into the HAT 5 V buck")
C("C18", "220n 25V X7R", "VCAP_5V", "5V_BUCK", "0603")
NMOS_Q3("Q3", "G_5VID", "5V_PI", "5V_BUCK", "CSD17578Q3A", mpn="CSD17578Q3A",
        note="30 V, low Rds(on); ideal-diode FET")
C("C19", "22u 10V X5R", "5V_PI", "GND", "0805")
R("R18", "2.2k", "5V_BUCK", "LED_5V_A", "0402")
part("D3", "LED", "GREEN", {1: "GND", 2: "LED_5V_A"}, fp="LED_SMD:LED_0402_1005Metric",
     note="HAT 5 V buck running")

# ---------------------------------------------------------------------------
# Sheet 3 -- 3.3 V for HaLow
# ---------------------------------------------------------------------------
sheet("power_3v3")
part("U5", "LM74700", "LM74700QDBVRQ1", {
    1: "VCAP_ORA", 2: "GND", 3: "VSYS", 4: "OR_NODE", 5: "G_ORA", 6: "VSYS"},
    fp="Package_TO_SOT_SMD:SOT-23-6", mpn="LM74700QDBVRQ1", mfr="TI", tier="B",
    note="OR-ing path A: battery / adapter")
C("C20", "220n 25V X7R", "VCAP_ORA", "VSYS", "0603")
NMOS_Q3("Q4", "G_ORA", "OR_NODE", "VSYS", "CSD17578Q3A", mpn="CSD17578Q3A")
part("U6", "LM74700", "LM74700QDBVRQ1", {
    1: "VCAP_ORB", 2: "GND", 3: "5V_PI", 4: "OR_NODE", 5: "G_ORB", 6: "5V_PI"},
    fp="Package_TO_SOT_SMD:SOT-23-6", mpn="LM74700QDBVRQ1", mfr="TI", tier="B",
    note="OR-ing path B: Pi 5 V (USB-C only bench mode)")
C("C21", "220n 25V X7R", "VCAP_ORB", "5V_PI", "0603")
NMOS_Q3("Q5", "G_ORB", "OR_NODE", "5V_PI", "CSD17578Q3A", mpn="CSD17578Q3A",
        note="sees up to 13 V Vds when battery path wins")
C("C22", "10u 50V X7R", "OR_NODE", "GND", "1210")
C("C23", "10u 50V X7R", "OR_NODE", "GND", "1210")
C("C24", "100n 50V X7R", "OR_NODE", "GND", "0402", note="hot-loop cap: closest to VIN/GND")
part("U7", "TPS62933F", "TPS62933FDRLR", {
    1: "GND", 2: "EN_3V3", 3: "OR_NODE", 4: "GND", 5: "SW_3V3", 6: "BST_3V3", 7: "SS_3V3",
    8: "FB_3V3"},
    fp="Package_TO_SOT_SMD:SOT-583-8", mpn="TPS62933FDRLR", mfr="TI", tier="B",
    note="FCCM fixed 1.2 MHz (RT=GND); EN abs max 6 V -> open-drain pull-down only")
C("C25", "100n 16V", "BST_3V3", "SW_3V3")
C("C26", "22n 16V", "SS_3V3", "GND", note="soft start ~3.2 ms")
part("L2", "L", "2.2uH Isat>=5.8A", {1: "SW_3V3", 2: "3V3_BUCK"},
     fp="Inductor_SMD:L_Coilcraft_XxL4030", mpn="XGL4030-222MEC", mfr="Coilcraft")
C("C27", "22u 10V X5R", "3V3_BUCK", "GND", "0805")
C("C28", "22u 10V X5R", "3V3_BUCK", "GND", "0805")
R("R20", "31.6k 1%", "3V3_BUCK", "FB_3V3")
R("R21", "10.0k 1%", "FB_3V3", "GND", note="Vout = 0.8 V x (1 + 31.6/10) = 3.33 V")
C("C29", "DNP 22p", "3V3_BUCK", "FB_3V3", dnp=True, note="optional feed-forward")
R("R22", "20m 1% 0.5W", "3V3_BUCK", "3V3_SH", "1206",
  note="INA226 #2 shunt, upstream of every socket bulk cap")
part("U8", "INA226", "INA226AIDGSR", {
    1: "GND", 2: "3V3_PI", 3: "INA_ALERT_N", 4: "I2C1_SDA", 5: "I2C1_SCL", 6: "3V3_PI",
    7: "GND", 8: "3V3_SH", 9: "3V3_SH", 10: "3V3_BUCK"},
    fp="Package_SO:VSSOP-10_3x3mm_P0.5mm", mpn="INA226AIDGSR", mfr="TI", tier="B",
    note="I2C 0x41 (A0=VS, A1=GND): HaLow card current")
C("C30", "100n 16V", "3V3_PI", "GND")
C("C31", "10u 10V X5R", "3V3_SH", "GND", "0603", note="pi-filter input cap")
part("FB1", "FB", "600R@100MHz >=4A", {1: "3V3_SH", 2: "3V3_FILT"},
     fp="Inductor_SMD:L_1206_3216Metric", mpn="BLM31KN601SN1L", mfr="Murata",
     note="verify rating at BOM step: >=4 A, <=30 mOhm")
SJ("JP1", "3V3_FILT", "3V3_MPCIE", True, "MPCIE",
   note="cut to isolate the HaLow card rail")
# enable logic: 3.3 V on when LTC2955 is on OR LTC2955 unpowered (USB-C only) OR BENCH
NMOS_SOT23("Q8", "G33", "EN_3V3", "GND", note="pulls TPS62933F EN low when LTC2955 is off")
R("R23", "4.7M", "LTC_ENB", "G33",
  note="high value: BENCH (Q9 on) must not load LTC_ENB, or Q7 cannot turn 5 V off (review P2)")
NMOS_SOT23("Q9", "BENCH_G", "G33", "GND", note="BENCH override: keeps 3.3 V on")
R("R24", "100k", "BENCH_G", "GND")
C("C32", "2.2n 16V", "EN_3V3", "GND", note="EN has only a 0.7 uA pull-up: noise immunity")
SJ("JP2", "3V3_PI", "BENCH_G", False, "BENCH",
   note="close: HaLow 3.3 V forced on while the Pi 3.3 V is present")

# ---------------------------------------------------------------------------
# Sheet 4 -- soft power
# ---------------------------------------------------------------------------
sheet("softpower")
part("U9", "LTC2955TS8", "LTC2955ITS8-2#TRPBF", {
    1: "LTC_ON", 2: "LTC_KILL_N", 3: "LTC_TMR", 4: "GND", 5: "PWR_BTN_N", 6: "VSYS",
    7: "LTC_ENB", 8: "PWR_INT_N"},
    fp="Package_TO_SOT_SMD:TSOT-23-8", mpn="LTC2955ITS8-2#TRPBF", mfr="Analog Devices", tier="B",
    note="-2 = active-low EN-bar (900k to VIN when off); KILL blanking 304-720 ms")
C("C40", "100n 50V X7R", "VSYS", "GND")
R("R30", "1M", "LTC_ENB", "GND", note="gate = 0.53 x VSYS when off (<=9.7 V)")
C("C41", "1u 10V", "LTC_TMR", "GND", note="long-press force-off ~5.3 s")
SJ("JP3", "VSYS", "AUTO_A", False, "AUTO-ON",
   note="close: power-on automatically when input appears (mast relay / C0 / T0)")
R("R31", "787k 1%", "AUTO_A", "LTC_ON",
  note="AUTO-ON 7.10 V typ / 6.74 V min: above the 5 V buck EN max 6.55 V (review P1)")
R("R32", "100k 1%", "LTC_ON", "GND")
R("R33", "10k", "3V3_PI", "LTC_KILL_N", note="KILL high as soon as the Pi 3.3 V is up")
NMOS_SOT23("Q10", "KILL_REQ", "LTC_KILL_N", "GND", note="GPIO27 high (gpio-poweroff) -> power off")
R("R34", "100k", "KILL_REQ", "GND", note="reboot: GPIO27 default pull-down keeps power on")
R("R35", "10k", "PWR_INT_N", "3V3_PI")
part("SW1", "SW_PUSH", "on-board PWR", {1: "PWR_BTN_N", 2: "GND"},
     fp="Button_Switch_SMD:SW_SPST_EVQP7A", mpn="EVQ-P7A01P", mfr="Panasonic",
     note="low-profile side button for the bench")
part("J6", "CONN2", "PANEL BTN", {1: "PWR_BTN_N", 2: "GND"},
     fp="Connector_JST:JST_SH_SM02B-SRSS-TB_1x02-1MP_P1.00mm_Horizontal",
     mpn="SM02B-SRSS-TB", mfr="JST", note="to the IP67 panel push-button")
part("D4", "TVS_UNI", "TPD1E10B06", {1: "PWR_BTN_N", 2: "GND"},
     fp="Diode_SMD:D_0402_1005Metric", mpn="TPD1E10B06DPYR", mfr="TI", tier="C",
     note="ESD for the panel button wire")

# ---------------------------------------------------------------------------
# Sheet 5 -- Pi header, EEPROM
# ---------------------------------------------------------------------------
sheet("pi_header")
PI_HEADER = {  # physical pin -> net (BCM numbers in the comments)
    1: "3V3_PI", 2: "5V_PI", 3: "I2C1_SDA", 4: "5V_PI", 5: "I2C1_SCL", 6: "GND",
    7: "BAT_PRESENT_N",          # GPIO4
    8: "CONSOLE_TX",               # GPIO14
    9: "GND", 10: "CONSOLE_RX",    # GPIO15
    11: "HALOW_RESET_N",         # GPIO17
    12: "TPM_CS_N",              # GPIO18
    13: "KILL_REQ",              # GPIO27
    14: "GND", 15: "TPM_PIRQ_N",  # GPIO22
    16: "HALOW_WAKE",            # GPIO23
    17: "3V3_PI", 18: "HALOW_BUSY",  # GPIO24
    19: "SPI0_MOSI", 20: "GND", 21: "SPI0_MISO",  # GPIO10 / GPIO9
    22: "INA_ALERT_N",           # GPIO25
    23: "SPI0_SCLK", 24: "SPI0_CE0",  # GPIO11 / GPIO8
    25: "GND", 26: None,         # GPIO7 = SPI0 CE1, held by the base device tree
    27: "ID_SD", 28: "ID_SC",    # GPIO0 / GPIO1
    29: "HALOW_IRQ",             # GPIO5
    30: "GND", 31: "GNSS_PPS",   # GPIO6
    32: "UART5_TX", 33: "UART5_RX",  # GPIO12 / GPIO13
    34: "GND", 35: "SPI1_MISO",  # GPIO19
    36: "TPM_RST_N",             # GPIO16
    37: "PWR_INT_N",             # GPIO26
    38: "SPI1_MOSI",             # GPIO20
    39: "GND", 40: "SPI1_SCLK",  # GPIO21
}
part("J2", "PI_GPIO40", "Pi 40-pin (female, 11 mm stack)", PI_HEADER,
     fp="Connector_PinSocket_2.54mm:PinSocket_2x20_P2.54mm_Vertical",
     note="through-hole on the bottom side; 8.5 mm socket for 11 mm standoffs")
part("U10", "EEPROM_24", "CAT24C32WI-GT3", {
    1: "GND", 2: "GND", 3: "GND", 4: "GND", 5: "ID_SD", 6: "ID_SC", 7: "EEP_WP", 8: "3V3_PI"},
    fp="Package_SO:SOIC-8_3.9x4.9mm_P1.27mm", mpn="CAT24C32WI-GT3", mfr="onsemi", tier="A",
    note="HAT ID EEPROM 0x50 on I2C0; device-tree injection point -> write protected")
C("C50", "100n 16V", "3V3_PI", "GND")
R("R50", "10k", "EEP_WP", "3V3_PI", note="WP high = protected by default")
SJ("JP4", "EEP_WP", "GND", False, "EEP-WRITE", note="close only while programming the EEPROM")
R("R51", "3.9k", "ID_SD", "3V3_PI")
R("R52", "3.9k", "ID_SC", "3V3_PI")
R("R53", "10k", "INA_ALERT_N", "3V3_PI")
for i in range(1, 5):
    part(f"H{i}", "MH", "M2.5", {1: "GND"}, fp="MountingHole:MountingHole_2.7mm_M2.5_Pad_Via",
         note="Pi HAT mounting hole")

# ---------------------------------------------------------------------------
# Sheet 6 -- mPCIe
# ---------------------------------------------------------------------------
sheet("halow")
MPCIE = {n: None for n in range(1, 53)}
for n in (2, 24, 39, 41, 52):
    MPCIE[n] = "3V3_MPCIE"
for n in (4, 9, 15, 18, 21, 26, 27, 29, 34, 35, 37, 40, 43, 50):
    MPCIE[n] = "GND"
MPCIE.update({10: "HALOW_IRQ", 22: "HALOW_RESET_N", 31: "HALOW_BUSY", 33: "HALOW_WAKE",
              45: "SPI0_SCLK", 47: "SPI0_MISO", 49: "SPI0_MOSI", 51: "SPI0_CE0",
              53: "GND", 54: "GND"})
part("J3", "MPCIE52", "mPCIe 5.2H", MPCIE,
     fp="batman:MiniPCIe_Lianxin_XDMP-052-A01_H5.2", mpn="XDMP-052-A01", mfr="Lianxin (China)",
     lcsc="C7498130", note="pin 8 UIM_PWR not connected on the card -> GPIO18 freed for the TPM")
C("C60", "47u 6.3V X5R", "3V3_MPCIE", "GND", "1206")
C("C61", "47u 6.3V X5R", "3V3_MPCIE", "GND", "1206")
part("C62", "CP", "220u 6.3V polymer", {1: "3V3_MPCIE", 2: "GND"},
     fp="Capacitor_Tantalum_SMD:CP_EIA-7343-20_Kemet-V", mpn="T520V227M006ATE015", mfr="KEMET",
     note="7343-20: <=1.9 mm tall; absorbs HaLow TX bursts")
C("C63", "100n 16V", "3V3_MPCIE", "GND", note="at pins 2/52")
C("C64", "100n 16V", "3V3_MPCIE", "GND", note="at pins 39/41")
part("H5", "MH", "M2 SMT standoff ~3.1mm", {1: "GND"}, fp="batman:SMT_Standoff_M2_TBD",
     note="card hold-down; height TBD after measuring (spec V14)")
part("H6", "MH", "M2 SMT standoff ~3.1mm", {1: "GND"}, fp="batman:SMT_Standoff_M2_TBD")

# ---------------------------------------------------------------------------
# Sheet 7 -- security + RTC
# ---------------------------------------------------------------------------
sheet("security")
SJ("JP5", "3V3_PI", "3V3_SEC", True, "SEC",
   note="cut to isolate TPM / ATECC / RTC supply; I2C/SPI1 still back-power them through ESD diodes")
part("U11", "SLB9672", "SLB9672XU2.0", {
    1: "3V3_SEC", 14: "3V3_SEC", 22: "3V3_SEC", 8: "3V3_SEC",
    2: "GND", 9: "GND", 23: "GND", 32: "GND", 33: "GND", 16: "GND",
    10: "TPM_P10", 17: "TPM_RST_N", 18: "TPM_PIRQ_N", 19: "SPI1_SCLK", 20: "TPM_CS_N",
    21: "SPI1_MOSI", 24: "SPI1_MISO"},
    fp="Package_DFN_QFN:QFN-32-1EP_5x5mm_P0.5mm_EP3.6x3.6mm", mpn="SLB9672XU2.0 (orderable code: verify at M3)", mfr="Infineon", tier="A",
    note="NC 6/29/30 must float; GPIO 3/4/7 have internal pull-ups; NO test points on TPM nets")
C("C70", "100n 16V", "3V3_SEC", "GND", note="pin 1")
C("C71", "100n 16V", "3V3_SEC", "GND", note="pin 14")
C("C72", "100n 16V", "3V3_SEC", "GND", note="pin 22")
C("C73", "1u 10V", "3V3_SEC", "GND")
R("R60", "10k", "TPM_P10", "3V3_SEC", note="pin 10 pull-up (TCG compatibility)")
R("R61", "10k", "TPM_CS_N", "3V3_SEC", note="datasheet Fig 7: GPIO18 boots pulled down")
R("R62", "10k", "TPM_PIRQ_N", "3V3_SEC")
R("R63", "10k", "TPM_RST_N", "GND", note="hold TPM in reset until the gpio-hog releases it")
part("U12", "ATECC608", "ATECC608C-TFLXTLS", {4: "GND", 5: "I2C1_SDA", 6: "I2C1_SCL", 8: "3V3_SEC"},
     fp="Package_SO:SOIC-8_3.9x4.9mm_P1.27mm", mpn="ATECC608C-TFLXTLS (SOIC-8 suffix: verify at M3)", mfr="Microchip", tier="A",
     note="I2C 0x36 (TrustFLEX)")
C("C74", "100n 16V", "3V3_SEC", "GND")
part("U13", "RV3028", "RV-3028-C7", {
    1: "RTC_CLKOUT", 2: "RTC_INT_N", 3: "I2C1_SCL", 4: "I2C1_SDA", 5: "GND", 6: "VRTC",
    7: "3V3_SEC", 8: "RTC_EVI"},
    fp="batman:MicroCrystal_RV-3028-C7", mpn="RV-3028-C7 32.768kHz 1ppm TA QC", mfr="Micro Crystal",
    tier="A", note="I2C 0x52; trickle charge enabled by the overlay (trickle-resistor-ohms)")
C("C75", "100n 16V", "3V3_SEC", "GND")
R("R64", "100k", "RTC_EVI", "GND", note="EVI idle: verify against the RV-3028 Application Manual")
part("C76", "CP", "CPH3225A 11mF", {1: "VRTC", 2: "GND"},
     fp="batman:Seiko_CPH3225A", mpn="CPH3225A", mfr="Seiko Instruments",
     note="RTC backup; rated 3.3 V vs 3V3_SEC up to 3.4 V: confirm with Seiko limit")

# ---------------------------------------------------------------------------
# Sheet 8 -- GNSS
# ---------------------------------------------------------------------------
sheet("gnss")
SJ("JP6", "3V3_PI", "3V3_GNSS", True, "GNSS", note="cut to isolate the GNSS supply (UART5_TX idle-high still back-feeds RXD)")
part("U14", "MAXM10S", "MAX-M10S-00B", {
    1: "GND", 2: "UART5_RX", 3: "UART5_TX", 4: "GNSS_PPS", 5: None, 6: "3V3_GNSS",
    7: "3V3_GNSS", 8: "3V3_GNSS", 9: "GNSS_RST_N", 10: "GND", 11: "GNSS_RFIN", 12: "GND",
    13: None, 14: "GNSS_VCCRF", 15: "GNSS_VIOSEL", 16: None, 17: None, 18: "GNSS_SAFEBOOT_N"},
    fp="RF_GPS:ublox_MAX", mpn="MAX-M10S-00B", mfr="u-blox", tier="A",
    note="pinout cross-checked with KiCad RF_GPS lib; VIO_SEL/V_BCKP to verify vs datasheet UBX-20035208")
part("R80", "R", "DNP 0R", {1: "GNSS_VIOSEL", 2: "GND"}, fp=_R_FP["0402"], dnp=True,
     note="VIO_SEL option; open = default I/O level (verify)")
C("C80", "10u 10V", "3V3_GNSS", "GND", "0603")
C("C81", "100n 16V", "3V3_GNSS", "GND")
R("R81", "47R", "GNSS_VCCRF", "GNSS_BIAS", "1206",
  note="antenna short = 70 mA / 0.23 W (rated 0.25 W); 10 mA antenna sees ~2.9 V. Recheck vs integration manual")
C("C82", "10n 16V", "GNSS_BIAS", "GND")
part("L80", "L", "27nH", {1: "GNSS_BIAS", 2: "GNSS_ANT"}, fp="Inductor_SMD:L_0402_1005Metric",
     mpn="LQG15HS27NJ02D", mfr="Murata", note="RF choke for antenna DC bias")
C("C83", "47p C0G", "GNSS_ANT", "GNSS_RFIN", note="DC block in front of RF_IN")
part("J4", "COAX", "U.FL", {1: "GNSS_ANT", 2: "GND"},
     fp="Connector_Coaxial:U.FL_Hirose_U.FL-R-SMT-1_Vertical", mpn="U.FL-R-SMT-1(10)", mfr="Hirose",
     note="active patch antenna with SAW pre-filter; 50 ohm CPWG trace")

# ---------------------------------------------------------------------------
# Sheet 9 -- debug
# ---------------------------------------------------------------------------
sheet("debug")
part("J5", "TC2050", "Tag-Connect TC2050", {
    1: "TC_3V3", 2: "TC_TX", 3: "GND", 4: "TC_RX", 5: "TC_SCLK", 6: "TC_MOSI",
    7: "TC_MISO", 8: "TC_CS", 9: "TC_IRQ", 10: "TC_BUSY"},
    fp="Connector:Tag-Connect_TC2050-IDC-NL_2x05_P1.27mm_Vertical", mfr="Tag-Connect",
    note="console = passwordless root until #137 ships: release gate")
R("R48", "1k", "3V3_PI", "TC_3V3", note="sense only: an adapter that drives VCC cannot back-feed the Pi")
for i, (tc, net) in enumerate([("TC_TX", "CONSOLE_TX"), ("TC_RX", "CONSOLE_RX"), ("TC_SCLK", "SPI0_SCLK"),
                               ("TC_MOSI", "SPI0_MOSI"), ("TC_MISO", "SPI0_MISO"), ("TC_CS", "SPI0_CE0"),
                               ("TC_IRQ", "HALOW_IRQ"), ("TC_BUSY", "HALOW_BUSY")]):
    R(f"R{40 + i}", "0R", net, tc,
      note="R40-R47 debug links: fitted on dev boards, NOT fitted on production (HaLow keys cross SPI0)"
      if i == 0 else "")
# Test points (user decision 2026-09-27): clip-able Keystone pads only for battery, 5 V, the
# HaLow 3.3 V and one GND; everything else is a 1.5 / 1.0 mm probe pad. Signals that reach the
# 40-pin header are probed on the header's solder joints (exposed on the top side) instead.
POWER_TPS = [  # net, silkscreen text with the expected reading, clip-able
    ("VBAT_RAW", "VBAT 6-17V", True), ("5V_BUCK", "5V 5.10-5.25", True),
    ("3V3_MPCIE", "3V3 HaLow 3.2-3.4", True), ("GND", "GND", True),
    ("VSYS", "VSYS 6-17V", False), ("5V_PI", "5V_PI 5.0-5.2", False), ("OR_NODE", "OR 5-17V", False),
    ("3V3_BUCK", "3V3_BUCK 3.25-3.40", False), ("3V3_PI", "3V3_PI 3.2-3.4", False),
    ("3V3_SEC", "3V3_SEC 3.2-3.4", False), ("3V3_GNSS", "3V3_GNSS 3.2-3.4", False),
    ("VRTC", "VRTC 0-3.3", False), ("GND", "GND", False),
]
for i, (net, txt, big) in enumerate(POWER_TPS, start=1):
    TP(f"TP{i}", net, txt, big=big) if big else part(
        f"TP{i}", "TP", txt, {1: net}, fp="TestPoint:TestPoint_Pad_D1.5mm")
SIGNAL_TPS = [  # only nets that are NOT on the 40-pin header
    "GNSS_RST_N", "GNSS_SAFEBOOT_N", "PWR_BTN_N", "LTC_KILL_N", "LTC_ENB", "EN_5V", "EN_3V3",
    "PG_5V", "EF_FLT_N", "EF_SHDN", "RTC_CLKOUT", "RTC_INT_N",
]
n0 = len(POWER_TPS) + 1
for i, net in enumerate(SIGNAL_TPS):
    TP(f"TP{n0 + i}", net, net)
n1 = n0 + len(SIGNAL_TPS)
for i, (net, txt) in enumerate([("EF_OUT", "K1+ (R9)"), ("VSYS", "K1- (R9)"),
                                ("3V3_BUCK", "K2+ (R22)"), ("3V3_SH", "K2- (R22)")]):
    TP(f"TP{n1 + i}", net, txt, note="Kelvin pads on the shunts: R9 mV x 100 = mA, R22 mV x 50 = mA"
       if i == 0 else "")
HEADER_PROBE = ["I2C1_SDA", "I2C1_SCL", "ID_SD", "ID_SC", "UART5_TX", "UART5_RX", "GNSS_PPS",
                "PWR_INT_N", "KILL_REQ", "BAT_PRESENT_N", "INA_ALERT_N", "HALOW_RESET_N", "HALOW_WAKE"]

# Power flags: tell KiCad ERC which nets are supplies (no electrical content).
POWER_NETS = ["GND", "VBAT_RAW", "EF_IN", "EF_OUT", "VSYS", "5V_BUCK", "5V_PI", "OR_NODE",
              "3V3_BUCK", "3V3_SH", "3V3_FILT", "3V3_MPCIE", "3V3_PI", "3V3_SEC", "3V3_GNSS",
              "VRTC"]
for i, net in enumerate(POWER_NETS, start=1):
    part(f"#FLG{i:02d}", "PWR_FLAG", "PWR_FLAG", {1: net})

# ---------------------------------------------------------------------------
# Facts the checker verifies (kept next to the data they describe)
# ---------------------------------------------------------------------------
# spec 4.2: BCM GPIO -> net. Physical pin mapping is the standard Pi 40-pin map.
BCM_TO_PHYS = {2: 3, 3: 5, 4: 7, 17: 11, 27: 13, 22: 15, 10: 19, 9: 21, 11: 23, 0: 27,
               5: 29, 6: 31, 13: 33, 19: 35, 26: 37, 14: 8, 15: 10, 18: 12, 23: 16,
               24: 18, 25: 22, 8: 24, 7: 26, 1: 28, 12: 32, 16: 36, 20: 38, 21: 40}
SPEC_GPIO = {0: "ID_SD", 1: "ID_SC", 2: "I2C1_SDA", 3: "I2C1_SCL", 4: "BAT_PRESENT_N",
             5: "HALOW_IRQ", 6: "GNSS_PPS", 7: None, 8: "SPI0_CE0", 9: "SPI0_MISO",
             10: "SPI0_MOSI", 11: "SPI0_SCLK", 12: "UART5_TX", 13: "UART5_RX",
             14: "CONSOLE_TX", 15: "CONSOLE_RX", 16: "TPM_RST_N", 17: "HALOW_RESET_N",
             18: "TPM_CS_N", 19: "SPI1_MISO", 20: "SPI1_MOSI", 21: "SPI1_SCLK",
             22: "TPM_PIRQ_N", 23: "HALOW_WAKE", 24: "HALOW_BUSY", 25: "INA_ALERT_N",
             26: "PWR_INT_N", 27: "KILL_REQ"}

# Worst-case DC voltage on nets that touch voltage-limited pins (V).
VBAT_MAX = 19.6  # eFuse OVP trip, worst case
NET_VMAX = {
    "GND": 0, "VBAT_RAW": 22.2, "EF_IN": VBAT_MAX, "EF_OUT": VBAT_MAX, "VSYS": VBAT_MAX,
    "OR_NODE": VBAT_MAX, "5V_BUCK": 5.3, "5V_PI": 5.3, "3V3_PI": 3.4, "3V3_SEC": 3.4,
    "3V3_GNSS": 3.4, "3V3_BUCK": 3.4, "3V3_SH": 3.4, "3V3_FILT": 3.4, "3V3_MPCIE": 3.4,
    "EN_3V3": 3.0,       # internal 0.7 uA pull-up only, open-drain pull-down
    "LTC_KILL_N": 3.4, "PWR_INT_N": 3.4, "INA_ALERT_N": 3.4, "BAT_PRESENT_N": 3.4,
    "KILL_REQ": 3.4, "EN_5V": VBAT_MAX * 24.3 / (102 + 24.3), "LTC_ENB": VBAT_MAX,
    "G33": VBAT_MAX * 1000 / 1900, "BATP_G": 22.2 / 2, "BENCH_G": 3.4,
    "EF_UVLO": 22.2 * 100 / 483, "EF_OVP": 22.2 * 100 / 1530, "EF_PGTH": VBAT_MAX * 100 / 483,
    "LTC_ON": VBAT_MAX * 100 / 781,
}
# Nets that intentionally reach only one IC pin (+ a test point), with the reason.
SINGLE_PIN_OK = {
    "EF_SHDN": "TPS2663 SHDN open-circuit 2.48-3.3 V > 2 V threshold = enabled; TP to force off",
    "RTC_CLKOUT": "unused output; TP to measure 32.768 kHz accuracy",
    "RTC_INT_N": "unused open-drain output; TP for alarm debug",
    "GNSS_RST_N": "internal pull-up; TP to reset the receiver",
    "GNSS_SAFEBOOT_N": "internal pull-up; TP to enter safe boot for firmware recovery",
}
# (part value prefix, pin) -> abs max voltage from the datasheets
PIN_VMAX = {
    ("TPS62933F", "2"): 6.0, ("TPS62933F", "3"): 32.0,
    ("TPS26631", "6"): 5.5, ("TPS26631", "7"): 5.5, ("TPS26631", "15"): 67.0,
    ("TPS26631", "16"): 67.0, ("TPS26631", "5"): 67.0,
    ("LMR33640", "3"): VBAT_MAX + 0.3, ("LMR33640", "2"): 38.0,
    ("LTC2955", "2"): 6.0, ("LTC2955", "6"): 40.0, ("LTC2955", "8"): 6.0,
    ("LTC2955", "7"): 40.0, ("LTC2955", "1"): 40.0,
    ("INA226", "6"): 6.0, ("INA226", "10"): 40.0, ("INA226", "9"): 40.0, ("INA226", "8"): 40.0,
    ("INA226", "3"): 6.0,
    ("BSS138", "1"): 20.0, ("BSS138", "3"): 50.0,
}
