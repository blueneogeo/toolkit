@Composable
fun PinnedBottomBar(content: @Composable () -> Unit) = BottomActionBar(content)

@Composable
private fun BottomActionBar(content: @Composable () -> Unit) = content()
