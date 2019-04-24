# AVFoundationLooper

Uses an input tap and an AVAudioPlayerNode to play loops!

On record start, AVAudioPCMBuffers and thier correlated AVAudioTimes are collected into an array. On record end (loop start), the (sometimes partial) buffers that fall into the time frame are joined into one buffer. 

In order to start playback of this buffer at the exact time that the button is pressed, we need to truncate this first buffer a little, so it's not suitable for looping.

At recordingStop, we may or may not have all of our audio, if we do have all of it, we join all of the buffers to make up an entire loop, then schedule it to play following the partial buffer that was previously scheduled.

If at recordingStop, we do NOT have the tail of our audio yet, we enter the `awaitingRecordingStop` state. In this state, each incoming buffer will be scheduled to play until we get to our `recordingStop` timestamp. 

Then, we join and schedule the full buffer to be looped.


### TODO:
Recording duration is sample accurate, but hardware IO latencies need to be integrated.

The loop ends should be cross-faded rather than the existing hard transition.
