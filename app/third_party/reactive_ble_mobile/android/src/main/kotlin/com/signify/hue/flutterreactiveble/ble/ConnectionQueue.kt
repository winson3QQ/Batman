package com.signify.hue.flutterreactiveble.ble

import androidx.annotation.VisibleForTesting
import io.reactivex.subjects.BehaviorSubject

internal class ConnectionQueue {
    private val queueSubject = BehaviorSubject.createDefault(listOf<String>())

    fun observeQueue() = queueSubject

    // PATCHED (Batman, #329): add runs on the platform thread, remove on the RxAndroidBle callbacks
    // thread, the computation thread (timeout / delayed disconnect) or, with the DeviceConnector
    // patch, the platform thread (dispose). Both are read-copy-onNext; the lock keeps one from
    // overwriting the other's update (a lost remove leaves a dead head entry: a permanent wedge)
    // and serialises onNext on the BehaviorSubject as the Rx contract requires.
    @Synchronized
    fun addToQueue(deviceId: String) {
        if (queueSubject.value?.find { it == deviceId } == null) {
            queueSubject.value?.let { currentQueue ->
                val newQueue = currentQueue.toMutableList()
                newQueue.add(deviceId)
                queueSubject.onNext(newQueue)
            }
        }
    }

    @VisibleForTesting
    internal fun getCurrentQueue() = queueSubject.value

    @Synchronized
    fun removeFromQueue(deviceId: String) {
        queueSubject.value?.let { currentQueue ->
            val newQueue = currentQueue.toMutableList()
            newQueue.remove(deviceId)
            queueSubject.onNext(newQueue)
        }
    }
}
