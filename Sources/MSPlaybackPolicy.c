#include "MSPlaybackPolicy.h"
#include <math.h>

int MSShouldPersistProgress(double seconds, double durationSeconds) {
    return isfinite(seconds) && isfinite(durationSeconds) &&
           durationSeconds > 10.0 && seconds >= 5.0 &&
           seconds < durationSeconds - 10.0;
}

double MSResumePosition(double savedSeconds, double durationSeconds) {
    return MSShouldPersistProgress(savedSeconds, durationSeconds) ? savedSeconds : 0.0;
}
