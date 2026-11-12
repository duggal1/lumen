import Testing
import LumenCapture
import LumenProject
import LumenRender

@Test func standardScreenCapturePreservesMoreDetail() {
    #expect(RecordingConfig.Quality.standard.bitsPerPixel >= 0.14)
    #expect(RecordingConfig.Resolution.ultraHD.resolutionHeight == 2160)
}

@Test func zoomUpscalingCanReachTenTimesWhenNeeded() {
    #expect(CameraParams().upscaleMaxFactor == 10)
    #expect(Upscaler.factor(forMagnification: 9, maxFactor: 10) == 10)
}
