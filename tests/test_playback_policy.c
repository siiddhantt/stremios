#include "MSPlaybackPolicy.h"

#include <math.h>
#include <stdio.h>

struct Case {
    const char *name;
    double saved;
    double duration;
    double expected_resume;
    int expected_persist;
};

int main(void) {
    const struct Case cases[] = {
        {"ordinary saved position", 120.0, 634.584, 120.0, 1},
        {"minimum saved position", 5.0, 634.584, 5.0, 1},
        {"position below minimum", 4.999, 634.584, 0.0, 0},
        {"zero position", 0.0, 634.584, 0.0, 0},
        {"negative position", -1.0, 634.584, 0.0, 0},
        {"exact end exclusion boundary", 90.0, 100.0, 0.0, 0},
        {"just outside end exclusion", 89.999, 100.0, 89.999, 1},
        {"near end", 99.0, 100.0, 0.0, 0},
        {"at duration", 100.0, 100.0, 0.0, 0},
        {"beyond duration", 101.0, 100.0, 0.0, 0},
        {"unknown duration", 20.0, NAN, 0.0, 0},
        {"infinite live duration", 20.0, INFINITY, 0.0, 0},
        {"negative infinite duration", 20.0, -INFINITY, 0.0, 0},
        {"zero duration", 5.0, 0.0, 0.0, 0},
        {"negative duration", 5.0, -100.0, 0.0, 0},
        {"duration at ten seconds", 5.0, 10.0, 0.0, 0},
        {"short clip with no resumable region", 5.0, 15.0, 0.0, 0},
        {"short clip with a resumable region", 5.0, 15.001, 5.0, 1},
        {"NaN saved position", NAN, 100.0, 0.0, 0},
        {"positive infinite position", INFINITY, 100.0, 0.0, 0},
        {"negative infinite position", -INFINITY, 100.0, 0.0, 0},
        {"both values invalid", NAN, NAN, 0.0, 0}
    };
    unsigned failures = 0;
    const unsigned count = (unsigned)(sizeof(cases) / sizeof(cases[0]));
    for (unsigned i = 0; i < count; ++i) {
        double actual_resume = MSResumePosition(cases[i].saved, cases[i].duration);
        int actual_persist = MSShouldPersistProgress(cases[i].saved, cases[i].duration);
        if (!isfinite(actual_resume) ||
            fabs(actual_resume - cases[i].expected_resume) > 0.000001 ||
            actual_persist != cases[i].expected_persist) {
            fprintf(stderr, "FAIL %s: resume=%g (expected %g), persist=%d (expected %d)\n",
                    cases[i].name, actual_resume, cases[i].expected_resume,
                    actual_persist, cases[i].expected_persist);
            ++failures;
        }
    }
    if (failures) return 1;
    printf("PASS %u playback-policy cases against production C implementation\n", count);
    return 0;
}
