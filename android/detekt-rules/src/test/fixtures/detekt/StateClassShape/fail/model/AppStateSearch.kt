@Stable
open class SearchState {
    var query by mutableStateOf("")

    fun reset() {
        query = ""
    }
}
