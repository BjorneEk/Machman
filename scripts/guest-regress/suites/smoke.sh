# A first look at a real guest (VM backends only: in a container every suite already starts
# from a fresh image, and there is no OS of its own to detect): the assembled script plans a
# run on this OS and init, and its report-only refresh writes the report Machman reads.
# CHECKS: SMOKE_PLAN SMOKE_REPORT
. /mnt/machman/share/regress/lib.sh

$SH "$S" -n -y --user root --no-install --no-service >/tmp/plan.log 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -Eq '^  guest +[a-z]' /tmp/plan.log \
	&& grep -q 'Dry run' /tmp/plan.log; then
	R SMOKE_PLAN pass
else
	R SMOKE_PLAN "fail (exit $rc)"; tail -n 12 /tmp/plan.log
fi
rm -f "$REPORT"
$SH "$S" --report-only -q >/tmp/report.log 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^STATUS=' "$REPORT" 2>/dev/null \
	&& grep -q '^OS_ID=' "$REPORT" && grep -q '^INIT=' "$REPORT"; then
	R SMOKE_REPORT pass
	grep -E '^(STATUS|OS_ID|INIT)=' "$REPORT"
else
	R SMOKE_REPORT "fail (exit $rc)"; tail -n 8 /tmp/report.log; cat "$REPORT" 2>/dev/null
fi
exit 0
