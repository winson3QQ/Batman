package node

// settings.set (docs/design/254-p3-impl.md §3.3, D9 / D14 / D20): one setting per call, owner-op verified by
// ownerOpVerb. Key 2 = the HaLow country (only while not in a network, radio managed); key 20 = the phone AP
// {1: ssid, 2: passphrase} (radio managed). halow-setkey does the change and goes back to the previous state itself
// when it does not read back or persist (its --rollback). Key 1 stays rename-pending until U5 (D8); keys 10-13 ->
// E_UNSUPPORTED reason 7 (the channel goes through network/update). On success the settings cache is re-read and
// the applied settings are the answer.

import (
	"strings"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

// reason codes (CDDL reason-code; 254-p3-impl §3.1-8)
const (
	ReasonNoCapability = 7  // this hardware has no such setting / parameter
	ReasonBadValue     = 13 // a value refused (or not read back: the node went back to the previous one)
	ReasonCountryJoin  = 14 // the country changes only while not in a network
	ReasonLegacy       = 20 // a legacy node (radio not app-managed, D20)
)

// setkey's P3 exit codes (halow-setkey --rollback): 0 set (or already that value), 2 refused, 3 not read back
// (restored), 4 not persisted (restored), 5 busy (lock / staged changes / .txn / netifd not settled), 6 the restore did
// not verify (design D-6: setkeyResult); anything else = outcome unknown
func setkeyErr(rc int, what string) *Error {
	switch rc {
	case 0:
		return nil
	case 2, 3:
		return failR(EInput, ReasonBadValue, "%s: halow-setkey rc %d (value refused / not read back, previous value back)", what, rc)
	case 4:
		return fail(EStorage, "%s: halow-setkey rc 4 (not persisted, previous value back)", what)
	case 5:
		return fail(EBusy, "%s: halow-setkey rc 5 (busy)", what)
	}
	return fail(EApply, "%s: halow-setkey rc %d (outcome unknown — re-read settings)", what, rc)
}

// setkeyResult: setkeyErr plus D-6 — rc 6 is CRIT, remembered for status (key 15 settings_restore) until a set succeeds
func (n *Node) setkeyResult(rc int, what string) *Error {
	switch rc {
	case 0:
		if what == "phone AP" { // 0 = the AP verified on the air with its values; a country set verifies nothing of it
			n.settingsRestoreBad.Store(false)
		}
	case 2, 3, 4, 5:
	case 6:
		n.settingsRestoreBad.Store(true)
		n.Log("CRIT settings.set %s: halow-setkey rc 6 — the restore did not verify, the radio state is unknown (status key 15 settings_restore)", what)
		return failR(EApply, ReasonBadValue, "%s: halow-setkey rc 6 (restore not verified)", what)
	default: // a timeout (124) or a crash: stopped part-way, the state is as unknown as after rc 6 (A r3 m7)
		n.settingsRestoreBad.Store(true)
		n.Log("CRIT settings.set %s: halow-setkey rc %d — stopped part-way, the radio state is unknown (status key 15 settings_restore)", what, rc)
	}
	return setkeyErr(rc, what)
}

// the phone AP's values, as halow-setkey checks them (§3.3 F46): ssid 1-32 of [A-Za-z0-9 ._~+=,:@%^*-] without a blank
// at either end, passphrase 12-63 of the same set without the blank
const apChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+=,:@%^*-"

func apCharsOnly(s string, blank bool) bool {
	for _, c := range s {
		if !(c == ' ' && blank) && !strings.ContainsRune(apChars, c) {
			return false
		}
	}
	return true
}

func apSSIDOK(s string) bool {
	return len(s) >= 1 && len(s) <= 32 && s[0] != ' ' && s[len(s)-1] != ' ' && apCharsOnly(s, true)
}

func apPassOK(s string) bool { return len(s) >= 12 && len(s) <= 63 && apCharsOnly(s, false) }

func isCountryCode(s string) bool {
	return len(s) == 2 && s[0] >= 'A' && s[0] <= 'Z' && s[1] >= 'A' && s[1] <= 'Z'
}

func (n *Node) settingsSet(rec *provstore.Record, body cbor.Map) (cbor.Map, *Error) {
	var key uint64
	var val any
	count := 0
	for _, en := range body {
		k, ok := en.K.(uint64)
		if !ok {
			if sk, _ := en.K.(string); sk == "hostname" {
				return nil, fail(EUnsupported, "rename-pending") // P1's answer to a rename by name, kept (P-U7)
			}
			return nil, failR(EInput, ReasonBadValue, "settings.set: a text key")
		}
		switch {
		case k == 31: // the owner-op
			continue
		case k == 1:
			return nil, fail(EUnsupported, "rename-pending") // P-U7 / D8: no rename before U5
		case k >= 10 && k <= 13:
			return nil, failR(EUnsupported, ReasonNoCapability, "settings.set: key %d (the channel goes through network/update)", k)
		case k == 2 || k == 20:
			key, val = k, en.V
			count++
		default:
			continue // unknown uint keys are ignored (CDDL * uint => any)
		}
	}
	if count != 1 {
		return nil, failR(EInput, ReasonBadValue, "settings.set: exactly one of keys 2 / 20 (got %d)", count)
	}
	if !rec.RadioManaged {
		return nil, failR(EUnsupported, ReasonLegacy, "settings.set: a legacy node (radio not app-managed)")
	}
	switch key {
	case 2:
		cc, ok := val.(string)
		if !ok || !isCountryCode(cc) {
			return nil, failR(EInput, ReasonBadValue, "settings.set: country must be two capital letters")
		}
		if rec.Net != nil {
			return nil, failR(EReject, ReasonCountryJoin, "settings.set: the country changes only while not in a network")
		}
		rc := n.Sys.SetCountry(cc)
		n.settingsReread()
		if e := n.setkeyResult(rc, "country"); e != nil {
			return nil, e
		}
	case 20:
		m, ok := val.(cbor.Map)
		if !ok {
			return nil, failR(EInput, ReasonBadValue, "settings.set: key 20 must be {1: ssid, 2: passphrase}")
		}
		sv, _ := m.Get(1)
		pv, _ := m.Get(2)
		ssid, ok1 := sv.(string)
		pass, ok2 := pv.(string)
		if !ok1 || !ok2 {
			return nil, failR(EInput, ReasonBadValue, "settings.set: key 20 must be {1: ssid, 2: passphrase}")
		}
		if !apSSIDOK(ssid) || !apPassOK(pass) {
			return nil, failR(EInput, ReasonBadValue, "settings.set: the phone AP's ssid / passphrase outside the allowed set or length")
		}
		rc := n.Sys.SetAP(ssid, pass)
		n.settingsReread()
		if e := n.setkeyResult(rc, "phone AP"); e != nil {
			return nil, e
		}
	}
	return n.settingsAfterSet(), nil
}

// settingsAfterSet: the cache re-read now (the helper's own change is visible at once, §3.3), the applied settings back;
// an unreadable cache is not an error — the change is done, the app re-reads with settings/get.
func (n *Node) settingsAfterSet() cbor.Map {
	if n.settings == nil {
		return cbor.M()
	}
	m, e := n.settings.get() // fresh: settingsReread ran right after halow-setkey
	if e != nil {
		return cbor.M()
	}
	return m
}
