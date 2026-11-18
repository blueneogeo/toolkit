@Stable
class CameraState {
    var isRunning by mutableStateOf(false)

    fun reset() {
        isRunning = false
    }
}

@Stable
class AppState(val camera: CameraState)
