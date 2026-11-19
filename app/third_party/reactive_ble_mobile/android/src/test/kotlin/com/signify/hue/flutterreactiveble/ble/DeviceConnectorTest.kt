package com.signify.hue.flutterreactiveble.ble

import com.google.common.truth.Truth.assertThat
import com.polidea.rxandroidble2.RxBleConnection
import com.polidea.rxandroidble2.RxBleDevice
import com.signify.hue.flutterreactiveble.model.ConnectionState
import com.signify.hue.flutterreactiveble.utils.Duration
import io.mockk.MockKAnnotations
import io.mockk.every
import io.mockk.impl.annotations.MockK
import io.mockk.verify
import io.reactivex.Observable
import io.reactivex.subjects.BehaviorSubject
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test
import java.lang.Exception
import java.util.concurrent.TimeUnit

@DisplayName("DeviceConnector unit tests")
class DeviceConnectorTest {
    @MockK
    private lateinit var connection: RxBleConnection

    @MockK
    private lateinit var device: RxBleDevice

    @MockK
    private lateinit var connectionQueue: ConnectionQueue

    @MockK
    private lateinit var updateListener: (update: ConnectionUpdate) -> Unit

    private lateinit var sut: DeviceConnector
    private lateinit var subject: BehaviorSubject<List<String>>
    private val deviceId = "123"

    @BeforeEach
    fun setup() {
        MockKAnnotations.init(this)
        subject = BehaviorSubject.create()
        every { device.connectionState }.returns(RxBleConnection.RxBleConnectionState.DISCONNECTED)
        every { device.observeConnectionStateChanges() }.returns(Observable.just(RxBleConnection.RxBleConnectionState.CONNECTED))
        every { device.macAddress }.returns(deviceId)
        every { updateListener.invoke(allAny()) }.returns(Unit)

        every { connectionQueue.addToQueue(any()) }.returns(Unit)
        every { connectionQueue.observeQueue() }.returns(subject)
        every { connectionQueue.removeFromQueue(any()) }.returns(Unit)

        subject.onNext(listOf(device.macAddress))
        sut = DeviceConnector(device, Duration(0L, TimeUnit.MILLISECONDS), updateListener, connectionQueue)
    }

    @AfterEach
    fun teardown() {
        sut.disconnectDevice(deviceId)
    }

    @Nested
    @DisplayName("Successfull connection")
    inner class SuccesfullConnectionTest {
        @BeforeEach
        fun setup() {
            every { device.establishConnection(any()) }.returns(Observable.just(connection))
        }

        @Test
        @DisplayName("Add device to queue")
        fun addDeviceToQueue() {
            sut.connection.test()
            verify(exactly = 1) { connectionQueue.addToQueue(deviceId) }
        }

        @Test
        @DisplayName("Connects to device only once")
        fun connectOnlyOnce() {
            sut.connection.test()

            verify(exactly = 1) { device.establishConnection(allAny()) }
        }

        @Test
        @DisplayName("Does not connect when device is not in queue")
        fun doNotConnectWhenInQueue() {
            subject.onNext(listOf("Otherdevice", device.macAddress))
            sut.connection.test()

            verify(exactly = 0) { device.establishConnection(allAny()) }
        }

        @Test
        @DisplayName("Updates listeners in case of succesfull connection")
        fun updatesWhenSuccess() {
            sut.connection.test()

            verify(exactly = 1) { updateListener.invoke(ConnectionUpdateSuccess(deviceId, ConnectionState.CONNECTED.code)) }
        }

        @Test
        @DisplayName("Connects to device only once in casealready connected")
        fun connectOnlyOnceAlreadyConnected() {
            sut.connection.test()
            every { device.connectionState }.returns(RxBleConnection.RxBleConnectionState.CONNECTED)

            sut.connection.test()

            verify(exactly = 1) { device.establishConnection(allAny()) }
        }

        @Test
        @DisplayName("Remove device from queue")
        fun removeDeviceFromQueue() {
            sut.connection.test()
            verify(exactly = 1) { connectionQueue.removeFromQueue(deviceId) }
        }
    }

    @Nested
    @DisplayName("Failed connection")
    inner class NotSuccesfullConnectionTest {
        private val errorMessage = "aaa"

        @BeforeEach
        fun setup() {
            every { device.establishConnection(any()) }.returns(Observable.error(Exception(errorMessage)))
        }

        @Test
        @DisplayName("Returns connection failed when connecting failed")
        fun failedToConnect() {
            val observer = sut.connection.test()

            assertThat(observer.values().first()).isInstanceOf(EstablishConnectionFailure::class.java)
        }

        @Test
        @DisplayName("Updates listeners in case of failed connection")
        fun updatesWhenFailed() {
            sut.connection.test()

            verify(exactly = 1) { updateListener.invoke(ConnectionUpdateError(deviceId, errorMessage)) }
        }

        @Test
        @DisplayName("Remove device from queue")
        fun removeDeviceFromQueue() {
            sut.connection.test()
            verify(exactly = 1) { connectionQueue.removeFromQueue(deviceId) }
        }
    }

    @Test
    @DisplayName("Dispose observable in case disconnecting")
    fun disposeOnDisconnect() {
        every { device.connectionState }.returns(RxBleConnection.RxBleConnectionState.DISCONNECTED)

        sut.connection.test()

        sut.disconnectDevice(deviceId)

        assertThat(sut.connectionDisposable?.isDisposed).isTrue()

        verify(exactly = 1) { updateListener.invoke(ConnectionUpdateSuccess(deviceId, ConnectionState.DISCONNECTED.code)) }
    }

    // PATCHED (Batman, upstream #558): queue entry must be removed on every exit path, exactly once.
    @Nested
    @DisplayName("Queue cleanup (upstream #558)")
    inner class QueueCleanupTest {
        private val otherId = "456"
        private val realQueue = ConnectionQueue()

        private fun connector(
            id: String,
            establish: Observable<RxBleConnection>,
        ): DeviceConnector {
            val dev = io.mockk.mockk<RxBleDevice>()
            every { dev.macAddress }.returns(id)
            every { dev.connectionState }.returns(RxBleConnection.RxBleConnectionState.DISCONNECTED)
            every { dev.observeConnectionStateChanges() }.returns(Observable.never())
            every { dev.establishConnection(any()) }.returns(establish)
            return DeviceConnector(dev, Duration(0L, TimeUnit.MILLISECONDS), updateListener, realQueue)
        }

        @Test
        @DisplayName("Disconnect before first event removes the entry so later connects are not blocked")
        fun cancelBeforeFirstEventDequeues() {
            val blocker = connector(otherId, Observable.never())
            blocker.connection.test()
            val waiting = connector(deviceId, Observable.just(connection))
            waiting.connection.test()
            assertThat(realQueue.getCurrentQueue()).containsExactly(otherId, deviceId).inOrder()

            // Cancel the connect at the head of the queue before it produced any event.
            blocker.disconnectDevice(otherId)

            assertThat(realQueue.getCurrentQueue()).isEmpty()
            val next = connector(otherId, Observable.just(connection))
            val observer = next.connection.test()
            assertThat(observer.values().first()).isInstanceOf(EstablishedConnection::class.java)
            waiting.disconnectDevice(deviceId)
            next.disconnectDevice(otherId)
        }

        @Test
        @DisplayName("Delayed dispose after a quick disconnect does not remove a newer connect to the same address")
        fun delayedDisposeKeepsNewerEntry() {
            val first = connector(deviceId, Observable.just(connection).concatWith(Observable.never()))
            first.connection.test()
            assertThat(realQueue.getCurrentQueue()).isEmpty()

            // Within minTimeMsBeforeDisconnectingIsAllowed: dispose runs later on a timer.
            first.disconnectDevice(deviceId)
            val second = connector(deviceId, Observable.never())
            second.connection.test()
            assertThat(realQueue.getCurrentQueue()).containsExactly(deviceId)

            Thread.sleep(500)

            assertThat(realQueue.getCurrentQueue()).containsExactly(deviceId)
            second.disconnectDevice(deviceId)
            assertThat(realQueue.getCurrentQueue()).isEmpty()
        }
    }
}
