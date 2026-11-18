class UserDefaults {
    fun value(forKey: String): Any? = store[forKey]
}
