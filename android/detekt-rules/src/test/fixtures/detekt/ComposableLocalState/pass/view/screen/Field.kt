@Composable
fun Field() {
    var text by remember { mutableStateOf("") } // non-actionable: the draft lives only while the field is on screen
    val page = rememberSaveable { 0 } // non-actionable: the pager's page survives rotation
    val source = remember { MutableInteractionSource() }
}
