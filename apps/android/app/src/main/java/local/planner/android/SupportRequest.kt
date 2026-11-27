package local.planner.android

import android.content.ClipData
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.InputTransformation
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.maxLength
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.text.input.then
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.pm.PackageInfoCompat
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private const val MAX_SUPPORT_MESSAGE = 4000
private const val MAX_SUPPORT_SUBJECT = 120
private const val MAX_REPLY_EMAIL = 254
private val replyEmailPattern = Regex("""[^\s@,;<>"\x00-\x1f\x7f]+@[^\s@,;<>"\x00-\x1f\x7f]+\.[^\s@,;<>"\x00-\x1f\x7f]+""")
private val supportSubjectInput = InputTransformation.maxLength(MAX_SUPPORT_SUBJECT).then {
    if (asCharSequence().any(Char::isISOControl)) revertAllChanges()
}

internal data class SupportSubmission(
    val id: String,
    val subject: String,
    val message: String,
    val replyEmail: String,
    val appVersion: String,
    val appBuild: String,
    val osVersion: String,
    val deviceTime: String,
) {
    fun wire() = payload(
        "submissionId" to value(id),
        "subject" to value(subject),
        "message" to value(message),
        "replyEmail" to value(replyEmail),
        "platform" to value("android"),
        "appVersion" to value(appVersion),
        "appBuild" to value(appBuild),
        "osVersion" to value(osVersion),
        "deviceTime" to value(deviceTime),
    )
}

@Composable
internal fun SupportRequestDialog(profile: Profile, model: PlannerModel, close: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val installed = remember(context) {
        if (Build.VERSION.SDK_INT >= 33) {
            context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0)
        }
    }
    val appVersion = installed.versionName.orEmpty().ifBlank { "—" }
    val appBuild = PackageInfoCompat.getLongVersionCode(installed).toString()
    val osVersion = "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
    var deviceTime by rememberSaveable { mutableStateOf(supportTimeNow()) }
    val subject = rememberTextFieldState()
    val message = rememberTextFieldState()
    val replyEmail = key(profile.workspace) { rememberTextFieldState(profile.email) }
    var submissionId by rememberSaveable { mutableStateOf<String?>(null) }
    var submittedFields by rememberSaveable { mutableStateOf<String?>(null) }
    var code by rememberSaveable { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf(false) }
    var error by rememberSaveable { mutableStateOf<Int?>(null) }
    var copied by remember { mutableStateOf(false) }
    val accepted = code
    val replyAddress = replyEmail.text.toString().trim()
    val validReplyAddress = replyAddress.matches(replyEmailPattern)

    AlertDialog(
        onDismissRequest = { if (!sending) close() },
        title = { Text(stringResource(if (accepted == null) R.string.support_write else R.string.support_received)) },
        text = {
            if (accepted != null) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.support_code))
                    SelectionContainer { Text(accepted, style = MaterialTheme.typography.titleLarge) }
                }
            } else {
                Column(
                    Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    SupportTextField(
                        state = subject,
                        inputTransformation = supportSubjectInput,
                        placeholder = R.string.support_subject,
                        readOnly = sending,
                    )
                    SupportTextField(
                        state = message,
                        inputTransformation = InputTransformation.maxLength(MAX_SUPPORT_MESSAGE),
                        placeholder = R.string.support_description,
                        readOnly = sending,
                        lineLimits = TextFieldLineLimits.MultiLine(minHeightInLines = 3, maxHeightInLines = 8),
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(stringResource(R.string.support_reply_email), style = MaterialTheme.typography.titleSmall)
                        SupportTextField(
                            state = replyEmail,
                            inputTransformation = InputTransformation.maxLength(MAX_REPLY_EMAIL),
                            placeholder = R.string.email,
                            readOnly = sending,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        )
                        if (replyAddress.isNotEmpty() && !validReplyAddress) {
                            Text(stringResource(R.string.support_invalid_reply_email),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                        }
                    }
                    if (sending) LinearProgressIndicator(Modifier.fillMaxWidth())
                    error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                }
            }
        },
        confirmButton = {
            if (accepted != null) {
                TextButton(onClick = close) { Text(stringResource(R.string.close)) }
            } else {
                val focus = LocalFocusManager.current
                TextButton(enabled = subject.text.isNotBlank() && message.text.isNotBlank() && validReplyAddress && !sending, onClick = {
                    focus.clearFocus()
                    val title = subject.text.toString().trim()
                    val text = message.text.toString().trim()
                    val fields = json.toJson(listOf(title, text, replyAddress))
                    val id = submissionId?.takeIf { submittedFields == fields } ?: newId().also {
                        submissionId = it
                        submittedFields = fields
                        deviceTime = supportTimeNow()
                    }
                    val submission = SupportSubmission(id, title, text, replyAddress, appVersion, appBuild, osVersion, deviceTime)
                    sending = true
                    error = null
                    scope.launch {
                        try {
                            code = model.sendSupport(profile, submission)
                        } catch (failure: Exception) {
                            if (failure is CancellationException) throw failure
                            error = when {
                                failure is ServerFailure && (failure.code == "support_unavailable" || failure.status == 404) ->
                                    R.string.support_unavailable
                                failure is ServerFailure && failure.status == 429 -> R.string.support_rate_limited
                                failure is ServerFailure && failure.status == 401 -> R.string.support_sign_in_again
                                else -> R.string.support_send_error
                            }
                        } finally {
                            sending = false
                        }
                    }
                }) { Text(stringResource(R.string.support_send)) }
            }
        },
        dismissButton = {
            if (accepted != null) {
                val label = stringResource(R.string.support_code)
                TextButton(onClick = {
                    val clipboard = context.getSystemService(ClipboardManager::class.java)
                    clipboard?.setPrimaryClip(ClipData.newPlainText(label, accepted))
                    copied = clipboard != null
                }) { Text(stringResource(if (copied) R.string.support_code_copied else R.string.support_copy_code)) }
            } else {
                TextButton(onClick = close, enabled = !sending) { Text(stringResource(R.string.cancel)) }
            }
        },
    )
}

@Composable
private fun SupportTextField(
    state: TextFieldState,
    inputTransformation: InputTransformation,
    placeholder: Int,
    readOnly: Boolean,
    lineLimits: TextFieldLineLimits = TextFieldLineLimits.SingleLine,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
) {
    val name = stringResource(placeholder)
    TextField(
        state = state,
        modifier = Modifier.fillMaxWidth().semantics { contentDescription = name },
        placeholder = { Text(name, Modifier.clearAndSetSemantics {}) },
        readOnly = readOnly,
        inputTransformation = inputTransformation,
        lineLimits = lineLimits,
        keyboardOptions = keyboardOptions,
        contentPadding = TextFieldDefaults.contentPaddingWithoutLabel(start = 0.dp, end = 0.dp),
        colors = plannerTextFieldColors(),
    )
}

private fun supportTimeNow(): String = OffsetDateTime.now().withNano(0).format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)
