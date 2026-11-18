@Stable
class CameraState {
    var isRunning by mutableStateOf(false)
    var zoom by mutableFloatStateOf(1f)
    private var storedValue by mutableStateOf(0)
    var stored: Int
        get() = storedValue
        set(value) {
            storedValue = value
        }
    val limits = listOf(1f, 2f)

    fun reset() {
        isRunning = false
    }
}

enum class PaperCardState { Unwatched, Watched }

data class TakeState(var seconds: Int = 0)
