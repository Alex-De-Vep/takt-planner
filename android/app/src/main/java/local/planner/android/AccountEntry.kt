package local.planner.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

private enum class AccountForm { SignIn, Register, Verify, Reset, ResetCode }

@Composable
internal fun AccountEntry(cloud: CloudState, model: PlannerModel) {
    var form by rememberSaveable { mutableStateOf<AccountForm?>(null) }
    Scaffold { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            Column(Modifier.widthIn(max = 540.dp).fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (cloud.firstSyncPending) {
                    Heading(stringResource(R.string.first_sync))
                    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        cloud.savedProfile?.let { Text(it.email) }
                        Text(stringResource(if (cloud.needsLibrary) R.string.empty_library_hint else R.string.first_sync_hint))
                        if (cloud.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                        if (!cloud.needsLibrary) {
                            cloud.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                        }
                        Button(onClick = { model.firstSync(cloud.needsLibrary) }, enabled = !cloud.busy) {
                            Text(stringResource(if (cloud.needsLibrary) R.string.create_cloud_library else R.string.retry))
                        }
                        if (cloud.needsLibrary) {
                            OutlinedButton(onClick = { model.firstSync() }, enabled = !cloud.busy) {
                                Text(stringResource(R.string.retry))
                            }
                        }
                        cloud.savedProfile?.let { profile ->
                            TextButton(onClick = { form = null; model.logout(profile) }, enabled = !cloud.busy) {
                                Text(stringResource(R.string.sign_out))
                            }
                        }
                    }
                } else {
                    Welcome { mode ->
                        model.clearCloudMessage()
                        form = mode
                    }
                    if (form == null) cloud.message?.let { Text(stringResource(it), Modifier.padding(horizontal = 20.dp)) }
                }
            }
        }
    }
    if (form != null && !cloud.firstSyncPending) {
        AccountDialog(requireNotNull(form), cloud, model) { form = null }
    }
}

@Composable
private fun Welcome(open: (AccountForm) -> Unit) {
    val pager = rememberPagerState { 4 }
    val scope = rememberCoroutineScope()
    HorizontalPager(
        state = pager,
        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) { page ->
        val (icon, title, hint) = when (page) {
            0 -> Triple(R.drawable.ic_list, R.string.welcome_tasks, R.string.welcome_tasks_hint)
            1 -> Triple(R.drawable.ic_calendar, R.string.events, R.string.welcome_events_hint)
            2 -> Triple(R.drawable.ic_chat, R.string.chat, R.string.welcome_chat_hint)
            else -> Triple(R.drawable.ic_sync, R.string.welcome_account_title, R.string.welcome_account_hint)
        }
        Column(Modifier.padding(horizontal = 20.dp)) {
            EmptyPanel(
                icon, title, hint,
                header = {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            stringResource(R.string.app_name), Modifier.weight(1f),
                            style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                        )
                        Text(
                            stringResource(R.string.welcome_page, page + 1, pager.pageCount),
                            style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                footer = {
                    if (page == pager.pageCount - 1) {
                        Button(onClick = { open(AccountForm.SignIn) }, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.sign_in))
                        }
                        OutlinedButton(onClick = { open(AccountForm.Register) }, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.register))
                        }
                    } else {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                            TextButton(onClick = { open(AccountForm.SignIn) }) {
                                Text(stringResource(R.string.sign_in))
                            }
                            Button(onClick = { scope.launch { pager.animateScrollToPage(page + 1) } }) {
                                Text(stringResource(R.string.next))
                            }
                        }
                    }
                },
            )
        }
    }
}

@Composable
private fun AccountDialog(initial: AccountForm, cloud: CloudState, model: PlannerModel, dismiss: () -> Unit) {
    var mode by rememberSaveable { mutableStateOf(initial) }
    val server = cloud.savedProfile?.origin ?: DEFAULT_ORIGIN
    var email by rememberSaveable { mutableStateOf(cloud.savedProfile?.email.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var challenge by rememberSaveable { mutableStateOf("") }
    val confirming = mode in setOf(AccountForm.Verify, AccountForm.ResetCode)
    val validPassword = password.codePointCount(0, password.length) in 12..128
    val title = when (mode) {
        AccountForm.SignIn -> R.string.sign_in
        AccountForm.Register -> R.string.register
        AccountForm.Verify -> R.string.verify_email
        AccountForm.Reset, AccountForm.ResetCode -> R.string.reset_password
    }
    val action = when (mode) {
        AccountForm.SignIn -> R.string.sign_in
        AccountForm.Register, AccountForm.Reset -> R.string.request_code
        AccountForm.Verify -> R.string.verify_and_sign_in
        AccountForm.ResetCode -> R.string.save
    }
    val enabled = !cloud.busy && email.isNotBlank() && when (mode) {
        AccountForm.SignIn -> password.isNotBlank()
        AccountForm.Register -> validPassword
        AccountForm.Reset -> true
        else -> validPassword && code.length == 8 && challenge.isNotBlank()
    }
    val startChallenge = { request: AccountRequest, next: AccountForm ->
        model.requestCode(server, email, password, request) {
            challenge = it
            code = ""
            mode = next
        }
    }
    val close = { if (!cloud.busy) { model.clearCloudMessage(); dismiss() } }

    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (confirming) Text(stringResource(R.string.email_code_hint, email))
                if (!confirming) {
                    OutlinedTextField(email, { email = it }, label = { Text(stringResource(R.string.email)) },
                        singleLine = true, enabled = !cloud.busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
                }
                if (confirming) {
                    OutlinedTextField(code, { code = it.filter { digit -> digit in '0'..'9' }.take(8) },
                        label = { Text(stringResource(R.string.email_code)) }, singleLine = true, enabled = !cloud.busy,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
                if (mode != AccountForm.Reset) {
                    OutlinedTextField(password, { password = it },
                        label = { Text(stringResource(if (mode == AccountForm.ResetCode) R.string.new_password else R.string.password)) },
                        singleLine = true, enabled = !cloud.busy, visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        supportingText = if (mode != AccountForm.SignIn) ({ Text(stringResource(R.string.password_rules)) }) else null)
                }
                if (mode == AccountForm.SignIn) {
                    TextButton(onClick = {
                        model.clearCloudMessage()
                        password = ""
                        mode = AccountForm.Reset
                    }, enabled = !cloud.busy) { Text(stringResource(R.string.forgot_password)) }
                }
                if (mode == AccountForm.Verify || cloud.message == R.string.email_not_verified) {
                    TextButton(onClick = { startChallenge(AccountRequest.Resend, AccountForm.Verify) }, enabled = !cloud.busy) {
                        Text(stringResource(R.string.resend_code))
                    }
                }
                if (mode == AccountForm.ResetCode) {
                    TextButton(onClick = { startChallenge(AccountRequest.Reset, AccountForm.ResetCode) }, enabled = !cloud.busy) {
                        Text(stringResource(R.string.resend_code))
                    }
                }
                if (cloud.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                cloud.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                when (mode) {
                    AccountForm.SignIn -> model.login(server, email, password)
                    AccountForm.Register -> startChallenge(AccountRequest.Register, AccountForm.Verify)
                    AccountForm.Reset -> startChallenge(AccountRequest.Reset, AccountForm.ResetCode)
                    AccountForm.Verify, AccountForm.ResetCode -> model.confirmCode(
                        server, email, password, challenge, code, mode == AccountForm.ResetCode,
                    ) {
                        password = ""
                        mode = AccountForm.SignIn
                    }
                }
            }, enabled = enabled) { Text(stringResource(action)) }
        },
        dismissButton = { TextButton(onClick = close, enabled = !cloud.busy) { Text(stringResource(R.string.cancel)) } },
    )
}
