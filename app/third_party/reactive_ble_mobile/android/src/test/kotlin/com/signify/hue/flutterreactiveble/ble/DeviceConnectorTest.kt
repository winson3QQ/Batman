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

    // PATCHED (Batman, #329 fast retry, docs/design/329-fast-retry.md §2.1 (a)): a connector whose result is a
    // failure sends no synthesized DISCONNECTED on disconnectDevice; one that is connected, or cancelled while still
    // connecting, sends it as before. Only the updates after disconnectDevice are counted: the failure itself sends a
    // state DISCONNECTED (startWith of connectionState) with or without the patch.
    @Nested
    @DisplayName("No stale DISCONNECTED from a failed connector (#329)")
    inner class NoStaleDisconnectTest {
        private val realQueue = ConnectionQueue()
        private val updates = java.util.Collections.synchronizedList(mutableListOf<ConnectionUpdate>())

        private fun connector(establish: Observable<RxBleConnection>): DeviceConnector {
            val dev = io.mockk.mockk<RxBleDevice>()
            every { dev.macAddress }.returns(deviceId)
            every { dev.connectionState }.returns(RxBleConnection.RxBleConnectionState.DISCONNECTED)
            every { dev.observeConnectionStateChanges() }.returns(Observable.never())
            every { dev.establishConnection(any()) }.returns(establish)
            return DeviceConnector(dev, Duration(8000L, TimeUnit.MILLISECONDS), { u -> updates.add(u) }, realQueue)
        }

        private fun disconnectedAfter(
            c: DeviceConnector,
            waitBeforeMs: Long,
        ): Int {
            if (waitBeforeMs > 0) Thread.sleep(waitBeforeMs)
            updates.clear()
            c.disconnectDevice(deviceId)
            Thread.sleep(500) // past the 200 ms timer of the delayed branch
            return synchronized(updates) {
                updates.count { it == ConnectionUpdateSuccess(deviceId, ConnectionState.DISCONNECTED.code) }
            }
        }

        @Test
        @DisplayName("Failed, disconnect within 200 ms (timer branch): no DISCONNECTED")
        fun failedTimerBranch() {
            val c = connector(Observable.error(Exception("GATT status 133")))
            assertThat(c.connection.test().values().first()).isInstanceOf(EstablishConnectionFailure::class.java)
            assertThat(disconnectedAfter(c, 0)).isEqualTo(0)
        }

        @Test
        @DisplayName("Failed, disconnect after 200 ms (immediate branch): no DISCONNECTED")
        fun failedImmediateBranch() {
            val c = connector(Observable.error(Exception("GATT status 133")))
            assertThat(c.connection.test().values().first()).isInstanceOf(EstablishConnectionFailure::class.java)
            assertThat(disconnectedAfter(c, 250)).isEqualTo(0)
        }

        @Test
        @DisplayName("Connected: one DISCONNECTED, as before")
        fun connectedSends() {
            val c = connector(Observable.just(connection).concatWith(Observable.never()))
            assertThat(c.connection.test().values().first()).isInstanceOf(EstablishedConnection::class.java)
            assertThat(disconnectedAfter(c, 250)).isEqualTo(1)
        }

        @Test
        @DisplayName("Cancelled while connecting: DISCONNECTED sent, as before")
        fun connectingSends() {
            val c = connector(Observable.never())
            c.connection.test()
            // two: the synthesized one, and the state one when disposeSubscriptions first touches the lazy
            // connectionStatusUpdates (startWith of connectionState); both upstream behaviour, not this patch
            assertThat(disconnectedAfter(c, 0)).isEqualTo(2)
        }

        @Test
        @DisplayName("Connected, then dropped: no DISCONNECTED (the drop already went out)")
        fun droppedSendsNone() {
            val c = connector(Observable.just(connection).concatWith(Observable.error(Exception("GATT status 8"))))
            c.connection.test()
            assertThat(disconnectedAfter(c, 250)).isEqualTo(0)
        }
    }
}
