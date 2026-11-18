@Composable
fun Card(onTap: () -> Unit) {
    Box(Modifier.clickable(interactionSource = null, indication = null) { onTap() })
    Box(Modifier.combinedClickable(interactionSource = null, indication = null, onLongClick = onTap, onClick = onTap))
}
