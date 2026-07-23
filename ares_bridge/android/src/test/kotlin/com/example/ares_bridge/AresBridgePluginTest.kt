package com.example.ares_bridge

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.ArgumentCaptor
import org.mockito.Mockito
import kotlin.test.Test


internal class AresBridgePluginTest {
    @Test
    fun onMethodCall_getCapabilities_returnsAndroidSupport() {
        val plugin = AresBridgePlugin()

        val call = MethodCall("getCapabilities", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        val captor = ArgumentCaptor.forClass(Any::class.java)
        Mockito.verify(mockResult).success(captor.capture())
        val capabilities = captor.value as Map<*, *>
        kotlin.test.assertEquals("android", capabilities["platform"])
        kotlin.test.assertEquals(true, capabilities["isSupported"])
        kotlin.test.assertEquals(true, capabilities["supportsUsbAccessory"])
    }
}
