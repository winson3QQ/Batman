package com.signify.hue.flutterreactiveble.ble

import android.content.Context
import com.google.common.truth.Truth.assertThat
import com.polidea.rxandroidble2.RxBleClient
import com.polidea.rxandroidble2.RxBleConnection
import com.polidea.rxandroidble2.RxBleDevice
import com.signify.hue.flutterreactiveble.utils.Duration
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import io.reactivex.Observable
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.util.UUID
import java.util.concurrent.TimeUnit

// PATCHED (Batman, #329): a GATT operation that reaches the plugin after disconnectFromDevice must not
// create a connector. Upstream created one with timeout 0 (autoConnect, no timeout); it entered the
// ConnectionQueue, was never disposed, and every later connect to any address waited behind it.
// Real DeviceConnector + real ConnectionQueue; only RxBleClient / RxBleDevice are mocks.
private class RealConnectorClient(val rx: RxBleClient, ctx: Context) : ReactiveBleClient(ctx) {
    override fun initializeClient() {
        rxBleClient = rx
        activeConnections = mutableMapOf()
    }
}

@DisplayName("Orphan connector (#329)")
class OrphanConnectorTest {
    private val timeout = Duration(8000L, TimeUnit.MILLISECONDS)

    private fun dev(id: String): RxBleDevice {
        val d = mockk<RxBleDevice>()
        every { d.macAddress }.returns(id)
        every { d.connectionState }.returns(RxBleConnection.RxBleConnectionState.DISCONNECTED)
        every { d.observeConnectionStateChanges() }.returns(Observable.never())
        every { d.establishConnection(any()) }.returns(Observable.never())
        return d
    }

    @Test
    @DisplayName("GATT operations after disconnect fail at once, create no connector, and do not wedge later connects")
    fun gattAfterDisconnectDoesNotWedge() {
        val rx = mockk<RxBleClient>()
        val x = dev("X")
        val y = dev("Y")
        every { rx.getBleDevice("X") }.returns(x)
        every { rx.getBleDevice("Y") }.returns(y)
        val sut = RealConnectorClient(rx, mockk(relaxed = true))
        sut.initializeClient()

        sut.connectToDevice("X", timeout)
        sut.disconnectDevice("X") // the app cancelled the pending connect

        // The second method call of a read / write / subscribe, landing after the cancel.
        sut.discoverServices("X").test().assertErrorMessage("Device is not connected")
        val read = sut.readCharacteristic("X", UUID.randomUUID(), 0).test()
        assertThat(read.values().single()).isInstanceOf(CharOperationFailed::class.java)
        val write = sut.writeCharacteristicWithoutResponse("X", UUID.randomUUID(), 0, byteArrayOf(1)).test()
        assertThat(write.values().single()).isInstanceOf(CharOperationFailed::class.java)
        sut.setupNotification("X", UUID.randomUUID(), 0).test().assertComplete().assertNoValues()
        val mtu = sut.negotiateMtuSize("X", 100).test()
        assertThat(mtu.values().single()).isInstanceOf(MtuNegotiateFailed::class.java)

        assertThat(ReactiveBleClient.activeConnections).doesNotContainKey("X")
        verify(exactly = 0) { x.establishConnection(true) } // no autoConnect re-creation

        sut.connectToDevice("Y", timeout)
        verify(exactly = 1) { y.establishConnection(false) } // Y reaches connectGatt
    }

    @Test
    @DisplayName("control: without the late GATT op, Y reaches connectGatt")
    fun controlNoGattAfterDisconnect() {
        val rx = mockk<RxBleClient>()
        val x = dev("X")
        val y = dev("Y")
        every { rx.getBleDevice("X") }.returns(x)
        every { rx.getBleDevice("Y") }.returns(y)
        val sut = RealConnectorClient(rx, mockk(relaxed = true))
        sut.initializeClient()

        sut.connectToDevice("X", timeout)
        sut.disconnectDevice("X")
        sut.connectToDevice("Y", timeout)
        verify(exactly = 1) { y.establishConnection(false) }
    }
}
