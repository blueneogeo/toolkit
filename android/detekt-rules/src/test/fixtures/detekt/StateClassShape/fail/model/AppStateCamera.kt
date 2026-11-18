class CameraState {
    var isRunning by mutableStateOf(false)

    fun reset() {
        isRunning = false
    }
}
