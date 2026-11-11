package local.planner.android

import androidx.annotation.StringRes
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp

@Composable
internal fun PlannerTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    @StringRes placeholder: Int,
    enabled: Boolean = true,
    readOnly: Boolean = false,
    singleLine: Boolean = false,
    minLines: Int = 1,
    maxLines: Int = Int.MAX_VALUE,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    supportingText: @Composable (() -> Unit)? = null,
    textStyle: TextStyle = MaterialTheme.typography.bodyLarge,
) {
    val name = stringResource(placeholder)
    TextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.semantics { contentDescription = name },
        placeholder = { Text(name, Modifier.clearAndSetSemantics {}, style = textStyle) },
        enabled = enabled,
        readOnly = readOnly,
        singleLine = singleLine,
        minLines = minLines,
        maxLines = maxLines,
        keyboardOptions = keyboardOptions,
        visualTransformation = visualTransformation,
        supportingText = supportingText,
        textStyle = textStyle,
        colors = plannerTextFieldColors(),
    )
}

@Composable
internal fun OptionalEditorField(
    value: String,
    onValueChange: (String) -> Unit,
    @StringRes placeholder: Int,
    @StringRes addLabel: Int,
    enabled: Boolean,
    readOnly: Boolean = false,
) {
    val initiallyFilled = rememberSaveable { value.isNotEmpty() }
    var added by rememberSaveable { mutableStateOf(false) }
    if (initiallyFilled || added || value.isNotEmpty()) {
        EditorDetailField(value, onValueChange, placeholder, enabled, focusOnEntry = added, readOnly = readOnly)
    } else if (!readOnly) {
        TextButton(onClick = { added = true }, enabled = enabled) {
            Icon(painterResource(R.drawable.ic_add), contentDescription = null)
            Text(stringResource(addLabel), Modifier.padding(start = 8.dp))
        }
    }
}

@Composable
internal fun EditorDetailField(
    value: String,
    onValueChange: (String) -> Unit,
    @StringRes placeholder: Int,
    enabled: Boolean,
    focusOnEntry: Boolean,
    readOnly: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    PlannerTextField(
        value, onValueChange,
        Modifier.fillMaxWidth().onFocusChanged { focused = it.hasFocus }
            .revealAboveKeyboard(focused).focusOnEntry(focusOnEntry),
        placeholder = placeholder, enabled = enabled, readOnly = readOnly,
        maxLines = if (readOnly) Int.MAX_VALUE else 6,
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun Modifier.revealAboveKeyboard(enabled: Boolean = true): Modifier {
    val requester = remember { BringIntoViewRequester() }
    val keyboardInset = WindowInsets.ime.getBottom(LocalDensity.current)
    var height by remember { mutableIntStateOf(0) }
    LaunchedEffect(enabled, height, keyboardInset) {
        if (enabled && height > 0 && keyboardInset > 0) {
            withFrameNanos { }
            requester.bringIntoView()
        }
    }
    return bringIntoViewRequester(requester).onSizeChanged { height = it.height }
}

@Composable
internal fun plannerTextFieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = Color.Transparent,
    unfocusedContainerColor = Color.Transparent,
    disabledContainerColor = Color.Transparent,
    errorContainerColor = Color.Transparent,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent,
    disabledIndicatorColor = Color.Transparent,
    errorIndicatorColor = Color.Transparent,
    focusedLabelColor = Color.Transparent,
    unfocusedLabelColor = Color.Transparent,
    disabledLabelColor = Color.Transparent,
    errorLabelColor = Color.Transparent,
)
