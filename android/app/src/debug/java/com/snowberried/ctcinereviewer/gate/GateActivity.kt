package com.snowberried.ctcinereviewer.gate

import android.app.Activity
import android.net.Uri
import android.os.Bundle
import android.view.SurfaceHolder
import android.widget.FrameLayout
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.ExactFrameSession
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import com.snowberried.ctcinereviewer.media.VideoMetadata
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class GateActivity : Activity(), ExactFrameSession.Listener {
    data class ObservedResult(val result: FrameResult, val diagnostics: DecoderDiagnostics)

    private lateinit var session: ExactFrameSession
    private val surfaceReady = CountDownLatch(1)
    private val metadata = LinkedBlockingQueue<VideoMetadata>()
    private val indexes = LinkedBlockingQueue<IndexedVideo>()
    private val results = LinkedBlockingQueue<ObservedResult>()
    private val statuses = LinkedBlockingQueue<Pair<String, String?>>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        session = ExactFrameSession(this, this)
        val viewport = session.createViewport(this)
        viewport.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = surfaceReady.countDown()
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
            override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
        })
        setContentView(FrameLayout(this).apply { addView(viewport, FrameLayout.LayoutParams(-1, -1)) })
    }

    fun awaitSurface(timeoutSeconds: Long = 5): Boolean = surfaceReady.await(timeoutSeconds, TimeUnit.SECONDS)

    fun openFixture(uri: Uri) {
        metadata.clear()
        indexes.clear()
        results.clear()
        statuses.clear()
        session.open(uri)
    }

    fun requestFrame(index: Int) = session.requestFrame(index)
    fun cancel() = session.cancel()
    fun clearResults() = results.clear()
    fun awaitMetadata(timeoutSeconds: Long = 10): VideoMetadata? = metadata.poll(timeoutSeconds, TimeUnit.SECONDS)
    fun awaitIndex(timeoutSeconds: Long = 10): IndexedVideo? = indexes.poll(timeoutSeconds, TimeUnit.SECONDS)
    fun awaitResult(timeoutSeconds: Long = 20): ObservedResult? = results.poll(timeoutSeconds, TimeUnit.SECONDS)
    fun drainResults(): List<ObservedResult> = buildList { results.drainTo(this) }
    fun drainStatuses(): List<Pair<String, String?>> = buildList { statuses.drainTo(this) }

    override fun onStatus(status: String, detail: String?) {
        statuses += status to detail
    }

    override fun onVideoOpened(metadata: VideoMetadata) {
        this.metadata += metadata
    }

    override fun onVideoIndexed(video: IndexedVideo) {
        indexes += video
    }

    override fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics) {
        results += ObservedResult(result, diagnostics)
    }

    override fun onDestroy() {
        session.close()
        super.onDestroy()
    }
}
