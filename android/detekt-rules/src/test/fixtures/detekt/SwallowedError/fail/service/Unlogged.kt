fun load(): String? {
    try {
        return read()
    } catch (error: IOException) {
        return null
    }
}
