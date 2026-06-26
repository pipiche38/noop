package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Twin of the Swift TestBundleAssemblerTests: an injected serial is scrubbed in a non-sink file. */
class TestBundleAssemblerTest {

    @Test fun reScrubsEveryFileIncludingRawCapture() {
        val rawWithSerial = "{\"console\":\"connected to WHOOP 4C1594026 ok\"}"
        val entries = listOf(
            "report.txt" to "clean line".toByteArray(),
            "raw-capture.jsonl" to rawWithSerial.toByteArray())
        val scrubbed = TestBundleAssembler.redactEntries(entries)
        val raw = scrubbed.first { it.first == "raw-capture.jsonl" }.second
        val text = String(raw)
        assertFalse(text.contains("4C1594026"))
        assertTrue(text.contains("WHOOP <serial>"))
    }

    @Test fun stampsRedactionV2() {
        assertEquals("v2", TestBundleAssembler.REDACTION_VERSION)
    }
}
