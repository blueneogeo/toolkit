private val lock = ReentrantLock() // concurrent-safe: guards the index the encoder thread reads
private val main = Handler(Looper.getMainLooper())
// A thread (the encoder's) reads this.
fun start() {
    connectivity.registerDefaultNetworkCallback(
        callback,
        Handler(Looper.getMainLooper()),
    )
    future.addListener({ bind() }, ContextCompat.getMainExecutor(context))
    player.addListener(listener)
}
suspend fun read(file: File): String = withContext(io) { file.readText() } // concurrent-safe: runs on the IO dispatcher
