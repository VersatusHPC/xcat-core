fix(xcat-core): a purged node that still resolves hangs the nodepurge case

nodepurge/cases0 asserts that testnode1 and testnode2 stopped resolving. It runs "ping <node>"
with no count and expects a non-zero exit. When the name does not resolve the ping fails at
once, which is the passing path. When the name still resolves, which is the regression the case
exists to catch, the ping never returns. The cell stops there until the pipeline timeout kills
it, and the run loses its JUnit report, so the one case that finds a defect hides every other
result.

The two ping commands in xCAT-test/autotest/testcase/nodepurge/cases0 carry no count and no
deadline, so ping keeps sending until it is killed.

Both pings now run as "ping -c 1 -w 2". The assertion is unchanged: a name that does not
resolve, or that resolves to a host which does not answer, still exits non-zero.

xCAT-test/unit/autotest_ping_bounded.t reads the ping lines the case carries and executes them
against loopback, which resolves and answers, and against an RFC 2606 .invalid name. It requires
each command to terminate on its own and the .invalid form to exit non-zero. Every ping runs
under timeout(1) with its stdio on /dev/null. Both lines are reaped with rc 124 on the test
commit, so the test fails there.

Commits: c6c5124a7 test, afb162629 fix
