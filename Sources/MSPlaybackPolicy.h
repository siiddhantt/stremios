#ifndef MSPlaybackPolicy_h
#define MSPlaybackPolicy_h

double MSResumePosition(double savedSeconds, double durationSeconds);
int MSShouldPersistProgress(double seconds, double durationSeconds);

#endif
