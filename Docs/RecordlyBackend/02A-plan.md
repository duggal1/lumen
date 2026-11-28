# Backend phase 02A — native capture interruption routing
Base 39d43046b4638768ef38e6b0f72cd774daf85575. Independent implementation of the ownership principle from Recordly e17a6f7.
- ScreenCaptureKit delegate publishes a typed cause to RecordingSession without blocking its callback queue.
- Generation gates suppress late callbacks; first cause wins. Existing stop/finalize tasks remain the only owners. The normal Studio stop path joins them; it retains activity metadata, markers and project publication.
- Sleep/termination/low-disk use the same route; preserve the original cause locally. Verify at least one decodable video sample before clearing the recording journal.
- Explicit discard joins in-flight terminal writers before removing a bundle.
- Added generation/first-cause/receipt serialization regression. Real disconnect, permission revocation, disk full, startup/stop race and forced process death need physical Mac validation. Uncooperative writer/stage deadline cancellation and durable ownership across process restart remain follow-up; do not claim all Part 2 gates pass.
