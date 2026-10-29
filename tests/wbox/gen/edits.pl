#!/usr/bin/perl
# edits.pl VARIANT — apply one #254 -wbox mutant to the Batman tree in the current directory (254-h23 §4.2).
# Every edit must match exactly once; anything else dies (a patch generated from a half-applied mutant is worse
# than none).
use strict; use warnings;
my %DESC = (
	'rc9-unclaimed' => 'helper --boot treats p5 rc 9 (seeded, no prov) as unclaimed instead of legacy',
	'helper-norebuild' => 'helper --boot never rebuilds the overlay record from p5 (txn committed, overlay unusable, p5 newer)',
	'96-norestore' => '96 does not copy the p5 record and the helper does not restore identity / record from p5',
	'96-noprov' => '96 does not copy the p5 record (PCOPY=none)',
	'helper-exit1' => 'the helper binary is replaced by a shell script that exits 1',
	'helper-nojoinop' => 'net.apply network/join accepted without verifying the owner-op',
	'helper-noleave' => 'network.leave keeps the p6 mesh markers',
	'helper-notrial' => 'state-changing verbs accepted on a trial slot',
	'helper-clientchal' => "claim.verify takes the client's ClientChal (arg 6) instead of recomputing it",
	'helper-notxn' => 'the helper drops an unfinished .txn at boot instead of finishing it',
	'helper-noforget' => 'forgetting the mesh (network/leave, Finish) does nothing and reports success',
	'helper-alwaysforget' => 'a failed join always forgets instead of restoring the pre-change snapshot',
	'radio1-off' => '99zz-wbox-radio1-off disables radio1 on the slot\'s first boot',
	'chan' => 'init wbox-chan keeps radio1 off the p5 channel for >= 200 s after the radio exists',
	'helper-flap' => 'the helper exits 5 s after serving (procd respawns it)',
	'misc-l38' => 'autocommit does not wait for the helper prov-state when writer=99zz (L38; dry-run bind only)',
	'misc-l42' => 'autocommit takes a member without ota-armed.mesh as radio-only (L42; dry-run bind only)',
	'misc-l43' => 'autocommit ignores the arm boot_id of ota-armed.mesh (L43; dry-run bind only)',
	'misc-l51' => 'autocommit takes an ota-armed.mesh saying joined as radio-only (L51; dry-run bind only)',
);
if (@ARGV == 2 && $ARGV[0] eq '--describe') { print $DESC{$ARGV[1]} // die "unknown variant $ARGV[1]\n"; print "\n"; exit 0 }
my $v = shift or die "usage: edits.pl VARIANT | --describe VARIANT\n";
my %W = (
	'rc9-unclaimed' => '3f1a9c2e', 'helper-norebuild' => '7b2d04e1', '96-norestore' => 'c5e8a113',
	'96-noprov' => '1d6f72a9', 'helper-exit1' => '9a04be37', 'helper-nojoinop' => '52c9e0f4',
	'helper-noleave' => 'e3b71d58', 'helper-notrial' => '06ad4c9b', 'helper-clientchal' => 'b8f2316d',
	'helper-notxn' => '4e9c7a20', 'radio1-off' => '81d5f0c6', 'chan' => '2ac9e47f', 'helper-flap' => 'f4703b1d',
	'misc-l38' => '6a1c9e30', 'misc-l42' => 'b7e2d915', 'misc-l43' => '0f4a8c62', 'misc-l51' => '93d5e71b',
	'helper-noforget' => 'd41f8a27', 'helper-alwaysforget' => '5c90e3b6',
);
my $w = "WBOX-$v-" . ($W{$v} // die "unknown variant $v\n");
print "$w\n";

sub slurp { my $f = shift; open my $h, '<', $f or die "$f: $!"; local $/; my $s = <$h>; close $h; $s }
sub spit { my ($f, $s, $mode) = @_; open my $h, '>', $f or die "$f: $!"; print $h $s; close $h; chmod $mode, $f if $mode }
# ed FILE, sub { s/.../.../ } — the sub returns the number of substitutions; must be exactly 1
sub ed { my ($f, @subs) = @_; local $_ = slurp($f);
	for my $s (@subs) { my $n = $s->(); die "$f: edit matched $n times (want 1)\n" unless $n == 1 } spit($f, $_) }

my $BOOT = 'feed/batman-prov/src/boot/boot.go';
my $NODE = 'feed/batman-prov/src/node/node.go';
my $MAIN = 'feed/batman-prov/src/cmd/batman-provhelper/main.go';
my $WTXN = 'feed/batman-prov/src/node/wtxn.go';
my $S96  = 'feed/batman-provision/files/etc/uci-defaults/96-batman-config-migrate';
my $PMK  = 'feed/batman-provision/Makefile';
my $AC   = 'feed/batman-provision/files/usr/bin/batman-autocommit';

# misc-*: one autocommit judgement removed each (design 254-h23 §17.2, §20.2 lower-case names, §21.4 witness placement:
# a header comment + a log line where the shell syntax is safe — l38 in place of the deleted wait loop, l42 / l43 / l51
# right after `RADIO_REQ=1` on entering the member branch). Used only by binding /usr/bin/batman-autocommit during a
# dry-run arm, never OTA'd.
my $acwit = sub { my $w = shift; ed($AC, sub { s{^(# batman-autocommit[^\n]*\n)}{$1# $w — #254 -wbox misc mutant (bind-only, dry-run arms of prov-misc-254)\n}m }) };
my $acmember = sub { my ($w, $what) = @_; ed($AC, sub { s{(\t\tmember:\*\)\n\t\t\tRADIO_REQ=1\n)}{$1\t\t\tlog "$w: $what (mutant)"\n} }) };
my $HMK  = 'feed/batman-prov/Makefile';

# 96: the p5 record is not copied (PCOPY=none), the log line keeps its form ("copied=none")
my $s96 = sub { my $w = shift; ed($S96, sub {
	s{\tok\)\n\t\tmkdir -p "\$PROVDIR".*?\t\tlog "prov: state=\$PST copied=\$PCOPY" ;;}
	 {\tok)\n\t\tPCOPY=none   # $w: mutant, the p5 record is not copied\n\t\tlog "prov: state=\$PST copied=\$PCOPY ($w)" ;;}s }) };

my %do = (
	'rc9-unclaimed' => sub {
		ed($BOOT, sub { s{(\tcase 9: // seeded, no prov: legacy upgrade \(or an operator --seed wiped prov\)\n)}
			{$1\t\te.Log("$w: rc 9 taken as unclaimed (mutant)")\n} },
			sub { s{(\tcase 9: .*?)(\tcase 10: )}{ my ($b, $e) = ($1, $2); my $k = ($b =~ s/provstore\.Legacy/provstore.Unclaimed/g); die "no Legacy in case 9\n" unless $k >= 3; $b . $e }se });
	},
	'helper-norebuild' => sub {
		# 254-wireless-txn: --boot's "p5 newer" path AND Finish's resolve() both rebuild the overlay from p5; the
		# mutant removes both (otherwise the boot Finish would rebuild it and the negative control could not fail)
		ed($BOOT,
			# F41: ovRec == nil must not fall through to ovRec.Generation (nil dereference = crash loop)
			sub { s{\t\tcase ovRec == nil \|\| p5Rec\.Generation > ovRec\.Generation:\n.*?(\t\tcase ovRec\.Generation > p5Rec\.Generation:\n)}
				{\t\tcase ovRec == nil:\n\t\t\te.Log("$w: overlay record unusable, NOT rebuilt from p5 (mutant)")\n\t\t\treturn Result{RC: rc, Verdict: "unknown(norebuild)", Action: "none (mutant: no rebuild from p5)"}\n\t\tcase p5Rec.Generation > ovRec.Generation:\n\t\t\te.Log("$w: p5 newer, overlay NOT rebuilt (mutant)")\n\t\t\treturn Result{RC: rc, Verdict: ovRec.State, Action: "none (mutant: no rebuild from p5)"}\n$1}s });
		ed($WTXN, sub { s~\tswitch \{\n\tcase p5 != nil && \(ov == nil \|\| p5\.Generation > ov\.Generation\):\n~\tif p5 != nil && (ov == nil || p5.Generation > ov.Generation) {\n\t\tn.Log("$w: resolve: p5 newer, overlay NOT rebuilt (mutant)")\n\t}\n\tswitch {\n\tcase false:\n~ });
	},
	'helper-notxn' => sub {
		# 254-wireless-txn: the helper drops an unfinished .txn at boot instead of finishing it
		ed($BOOT, sub { s{\tres\.Unfinished = provstore\.TxnPresent\(e\.P\)\n}
			{\tif provstore.TxnPresent(e.P) {\n\t\tprovstore.RemoveTxn(e.P)\n\t\te.Log("$w: .txn dropped at boot, never finished (mutant)")\n\t}\n} });
	},
	'helper-noforget' => sub {
		# 254-wireless-txn §8 rejoin row: forgetting the mesh (leave and Finish) does nothing and reports success
		ed($MAIN, sub { s{\trc, out := run\(nil, "halow-setkey", "--forget-mesh", "--no-persist"\)\n}
			{\trc, out := 0, "$w: forget-mesh skipped (mutant)"\n\tlogf("%s", out)\n} });
	},
	'helper-alwaysforget' => sub {
		# 254-wireless-txn §8 legacyjoin row (review B r5 m5): a failed join always forgets instead of restoring the
		# operator's pre-change settings
		ed($WTXN, sub { s~\tif tx\.PrevKey == "" \|\| tx\.PrevKey == placeholderKey \{\n~\tif true { // mutant: the pre-change snapshot is never restored\n\t\tn.Log("$w: snapshot ignored, forgetting (mutant)")\n~ });
	},
	'helper-notrial' => sub {
		ed($NODE, sub { s{\tif stateChanging\[verb\] && n\.Sys\.IsTrial\(\) \{\n\t\treturn nil, fail\(EBusy, "trial slot \(updating\)"\)\n\t\}}
			{\tif stateChanging[verb] && n.Sys.IsTrial() {\n\t\tn.Log("$w: %s accepted on a trial slot (mutant)", verb)\n\t}} });
	},
	'helper-clientchal' => sub {
		ed($NODE,
			sub { s{(func \(n \*Node\) claimVerify\(rec \*provstore\.Record, a cbor\.Map\) \(cbor\.Map, \*Error\) \{\n\tif e := onlyKeys\(a, 1, 2, 3, 4, 5)\)}{$1, 6)} },
			sub { s~\tif !n\.KS\.CheckMac\(proto\.ClientChal\(nn, h, n\.KS\.Cert\(\), ownerPub\), resp\) \{~\tchal := proto.ClientChal(nn, h, n.KS.Cert(), ownerPub)\n\tif c, ok := a.Get(6); ok {\n\t\tif b, ok := c.([]byte); ok {\n\t\t\tchal = b\n\t\t\tn.Log("$w: the client's ClientChal adopted (mutant)")\n\t\t}\n\t}\n\tif !n.KS.CheckMac(chal, resp) {~ });
	},
	'helper-nojoinop' => sub {
		ed($NODE, sub { s{\tif e := n\.verifyOwnerOp\(h, typ, body, ownerPubs\(rec\)\); e != nil \{\n\t\treturn nil, e\n\t\}}
			{\tif verb == "net.apply" {\n\t\tn.Log("$w: network/join without an owner-op check (mutant)")\n\t} else if e := n.verifyOwnerOp(h, typ, body, ownerPubs(rec)); e != nil {\n\t\treturn nil, e\n\t}} });
	},
	'helper-noleave' => sub {
		ed($NODE, sub { s{\tif err := n\.Sys\.RemoveMeshMarkers\(\); err != nil \{\n\t\tn\.Log\("network\.leave: mesh markers: %v", err\)\n\t\}}
			{\tn.Log("$w: p6 mesh markers kept on leave (mutant)")} });
	},
	'helper-flap' => sub {
		ed($MAIN, sub { s{(\tlogf\("serving \(%s\)", res\.Verdict\)\n)}
			{$1\tgo func() {\n\t\ttime.Sleep(5 * time.Second)\n\t\tlogf("$w: exiting 5 s after serving (mutant)")\n\t\tos.Exit(1)\n\t}()\n} });
	},
	'96-noprov' => sub { $s96->($w) },
	'96-norestore' => sub {
		$s96->($w);
		ed($BOOT, sub { s{(\trestoreFromP5 := func\(\) error \{\n)}
			{$1\t\tif e.Log != nil {\n\t\t\te.Log("$w: not restoring identity / record from p5 (mutant)")\n\t\t\treturn errors.New("mutant: no restore from p5")\n\t\t}\n} });
	},
	'helper-exit1' => sub {
		ed($HMK, sub { s{\t\$\(call GoPackage/Package/Install/Bin,\$\(1\)\)\n}
			{\t# $w: mutant, the helper is a shell script that exits 1\n\t\$(INSTALL_DIR) \$(1)/usr/bin\n\t\$(INSTALL_BIN) ./files/wbox-helper-exit1.sh \$(1)/usr/bin/batman-provhelper\n} });
		spit('feed/batman-prov/files/wbox-helper-exit1.sh', "#!/bin/sh\n# $w — #254 -wbox test variant ONLY (Batman docs/design/254-h23-harness.md §4.2): the provisioning\n# helper replaced by a script that fails, so the lock must hold without it (prov-lock-failsecure).\nlogger -t batman-provhelper \"$w: helper replaced by exit 1 (mutant)\"\nexit 1\n", 0755);
	},
	'radio1-off' => sub {
		ed($PMK, sub { s{(\t\$\(INSTALL_BIN\) \./files/etc/uci-defaults/99zz-batman-prov-state +\$\(1\)/etc/uci-defaults/99zz-batman-prov-state\n)}
			{$1\t\$(INSTALL_BIN) ./files/etc/uci-defaults/99zz-wbox-radio1-off \$(1)/etc/uci-defaults/99zz-wbox-radio1-off\n} });
		spit('feed/batman-provision/files/etc/uci-defaults/99zz-wbox-radio1-off', "#!/bin/sh\n# 99zz-wbox-radio1-off — $w — #254 -wbox test variant ONLY (Batman docs/design/254-h23-harness.md §4.2):\n# the HaLow radio disabled on this slot's first boot, so the trial cannot join the mesh (autocommit (1)).\n# Runs after 99zz-batman-prov-state (name order) so 96's overrides do not write it back.\nuci -q set wireless.radio1.disabled=1 && uci -q commit wireless\nlogger -t wbox-radio1-off \"$w: radio1 disabled (mutant)\"\nexit 0\n", 0755);
	},
	'chan' => sub {
		ed($PMK, sub { s{(\t\$\(INSTALL_BIN\) \./files/etc/init\.d/joinwatch +\$\(1\)/etc/init\.d/joinwatch\n)}
			{$1\t\$(INSTALL_BIN) ./files/etc/init.d/wbox-chan \$(1)/etc/init.d/wbox-chan\n} });
		spit('feed/batman-provision/files/etc/init.d/wbox-chan', <<"EOS", 0755);
#!/bin/sh /etc/rc.common
# wbox-chan — $w — #254 -wbox test variant ONLY (Batman docs/design/254-h23-harness.md §4.2, F15):
# for >= 200 s after the HaLow radio exists, keep radio1 on a legal channel OTHER than the p5 one (morse's default 42,
# or 40 when p5 holds 42), so this trial cannot join the mesh — longer than 99-batman-chanfix keeps reasserting (80 s
# wait + 6 x 8 s). Then exit. Every reassert is logged with the witness.
START=99

start() {
	(
		P5=""
		MNT=\$(mktemp -d /tmp/wbox-chan.XXXXXX) && {
			mount -t ext4 -o ro,noload /dev/mmcblk0p5 "\$MNT" 2>/dev/null && {
				P5=\$(sed -n "s/.*wireless\\.radio1\\.channel=[\\"']\\{0,1\\}\\([0-9]\\{1,\\}\\)[\\"']\\{0,1\\}.*/\\1/p" "\$MNT/overrides.uci" 2>/dev/null | head -1)
				umount "\$MNT" 2>/dev/null
			}
			rmdir "\$MNT" 2>/dev/null
		}
		T=42; [ "\$P5" = 42 ] && T=40
		i=0
		while [ "\$i" -lt 60 ] && ! iw dev wlh0 info >/dev/null 2>&1; do sleep 2; i=\$((i + 1)); done
		n=0; t0=\$(cut -d. -f1 /proc/uptime)
		while [ \$((\$(cut -d. -f1 /proc/uptime) - t0)) -lt 210 ]; do
			if [ "\$(uci -q get wireless.radio1.channel)" != "\$T" ]; then
				uci set wireless.radio1.channel="\$T"; uci commit wireless; wifi reload; n=\$((n + 1))
				logger -t wbox-chan "wbox-chan: asserted \$T (\$n times) p5=\${P5:-?} $w"
			fi
			sleep 5
		done
		logger -t wbox-chan "wbox-chan: done after 210 s, asserted \$T (\$n times) p5=\${P5:-?} $w"
	) </dev/null >/dev/null 2>&1 &
}
EOS
	},
	'misc-l38' => sub {
		$acwit->($w);
		ed($AC, sub { s{^while \[ "\$\{pr%% \*\}" = 99zz \] && \[ "\$i" -lt 60 \]; do sleep 1; i=\$\(\(i \+ 1\)\); pr=\$\(prov_read\); done\n}{log "$w: not waiting for the helper's prov-state (mutant)"\n}m });
	},
	'misc-l42' => sub {
		$acwit->($w); $acmember->($w, 'a missing ota-armed.mesh counts as radio-only');
		ed($AC, sub { s{\t\t\telse NEED_MESH=1; \[ -n "\$a" \] \|\| log "member: no usable ota-armed.mesh — neighbours required \(fail-closed\)"; fi ;;}{\t\t\telif [ -z "\$a" ]; then NEED_MESH=0\n\t\t\telse NEED_MESH=1; fi ;;} });
	},
	'misc-l43' => sub {
		$acwit->($w); $acmember->($w, 'the arm boot_id of ota-armed.mesh is not checked');
		ed($AC, sub { s{ && \[ "\$\(echo "\$a" \| cut -d' ' -f1\)" = "\$ab" \]}{} });
	},
	'misc-l51' => sub {
		$acwit->($w); $acmember->($w, 'an ota-armed.mesh saying joined counts as radio-only');
		ed($AC, sub { s{\[ "\$\(echo "\$a" \| cut -d' ' -f3\)" = radio \]}{case "\$(echo "\$a" | cut -d' ' -f3)" in radio|joined) true ;; *) false ;; esac} });
	},
);
($do{$v} // die "no edits for $v\n")->();
