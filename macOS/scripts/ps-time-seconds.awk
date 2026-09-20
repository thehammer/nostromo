# Convert a macOS `ps -o time=` / `-o cputime=` value to seconds.
#
# The format is [[dd-]hh:]mm:ss[.ss] — the FIELD COUNT VARIES WITH RUNTIME, so
# any fixed mapping is wrong in both directions. The previous
# ($1*3600)+($2*60)+$3 read `30:38.67` (30 min 38 s) as 110320 s instead of
# 1838.67 — a 60x inflation that made the "idle CPU < 2%" criterion false-fail
# a genuinely idle app measuring 0.04%.
#
# Weights are applied right-to-left, so the same program handles mm:ss,
# hh:mm:ss and dd-hh:mm:ss.
#
# Empty input exits non-zero and prints nothing, so a caller whose process died
# mid-run can name the failure instead of feeding an empty string into
# arithmetic.
BEGIN { FS = "[:-]"; w[1] = 1; w[2] = 60; w[3] = 3600; w[4] = 86400; seen = 0 }
{
    gsub(/[ \t]/, "")
    if ($0 == "") next
    seen = 1
    s = 0
    for (i = 0; i < NF && i < 4; i++) s += $(NF - i) * w[i + 1]
    printf "%.2f\n", s
}
END { if (!seen) exit 1 }
