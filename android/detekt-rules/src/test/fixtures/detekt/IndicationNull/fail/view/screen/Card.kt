@Composable
fun Card(onTap: () -> Unit) {
    Box(Modifier.clickable { onTap() })
}
