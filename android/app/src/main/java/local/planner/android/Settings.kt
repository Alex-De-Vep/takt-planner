package local.planner.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@Composable
internal fun Settings(library: Library, cloud: CloudState, model: PlannerModel) {
    var signIn by rememberSaveable { mutableStateOf(false) }
    var signOut by rememberSaveable { mutableStateOf(false) }
    val profile = library.profile
    val saved = cloud.savedProfile
    Column(Modifier.verticalScroll(rememberScrollState())) {
        Heading(stringResource(R.string.settings), stringResource(R.string.workspace))
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerLow, shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth().padding(20.dp),
        ) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(stringResource(if (profile == null) R.string.local_library else R.string.cloud_library),
                    style = MaterialTheme.typography.titleLarge)
                if (profile != null) Text(profile.email, style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(if (profile == null) R.string.local_library_hint else R.string.cloud_library_hint),
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (cloud.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                val status = if (profile != null && cloud.requiresLogin) R.string.sign_in_again else cloud.message
                if (status != null) Text(stringResource(status), color = MaterialTheme.colorScheme.error)
                if (profile != null) {
                    if (library.pending > 0) Text(stringResource(R.string.pending, library.pending))
                    if (library.rejected > 0) {
                        Text(stringResource(R.string.rejected, library.rejected), color = MaterialTheme.colorScheme.error)
                    }
                    if (cloud.requiresLogin) {
                        Button(onClick = { signIn = true }, enabled = !cloud.busy) { Text(stringResource(R.string.sign_in)) }
                    } else {
                        Button(onClick = model::refresh, enabled = !cloud.busy) { Text(stringResource(R.string.sync_now)) }
                    }
                    OutlinedButton(onClick = model::local, enabled = !cloud.busy) { Text(stringResource(R.string.use_local)) }
                } else if (saved != null && !cloud.requiresLogin) {
                    Button(onClick = { model.online(saved) }, enabled = !cloud.busy) { Text(stringResource(R.string.use_cloud)) }
                } else {
                    Button(onClick = { signIn = true }, enabled = !cloud.busy) { Text(stringResource(R.string.sign_in)) }
                }
                if (saved != null && (!cloud.requiresLogin || profile != null)) {
                    TextButton(onClick = { signOut = true }, enabled = !cloud.busy) { Text(stringResource(R.string.sign_out)) }
                }
            }
        }
    }
    if (signIn) SignIn(saved, cloud, model) { signIn = false }
    if (signOut && saved != null) {
        Confirm(R.string.sign_out, R.string.sign_out_hint, R.string.sign_out, { signOut = false }) {
            signOut = false
            model.logout(saved)
        }
    }
}

@Composable
private fun SignIn(profile: Profile?, cloud: CloudState, model: PlannerModel, close: () -> Unit) {
    var server by rememberSaveable { mutableStateOf(profile?.origin ?: DEFAULT_ORIGIN) }
    var email by rememberSaveable { mutableStateOf(profile?.email.orEmpty()) }
    var password by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = { if (!cloud.busy) close() },
        title = { Text(stringResource(R.string.sign_in)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.sign_in_hint))
                OutlinedTextField(server, { server = it }, label = { Text(stringResource(R.string.server)) },
                    singleLine = true, enabled = !cloud.busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                OutlinedTextField(email, { email = it }, label = { Text(stringResource(R.string.email)) },
                    singleLine = true, enabled = !cloud.busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
                OutlinedTextField(password, { password = it }, label = { Text(stringResource(R.string.password)) },
                    singleLine = true, enabled = !cloud.busy, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                if (cloud.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                cloud.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(onClick = { model.login(server, email, password, close) },
                enabled = !cloud.busy && email.isNotBlank() && password.isNotBlank()) { Text(stringResource(R.string.sign_in)) }
        },
        dismissButton = { TextButton(onClick = close, enabled = !cloud.busy) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun Folders(library: Library, model: PlannerModel, close: () -> Unit) {
    var action by rememberSaveable { mutableStateOf<String?>(null) }
    val dismiss = { action = null }
    when (val dialog = action) {
        "new" -> NameDialog(R.string.new_folder, R.string.folder_name, "", dismiss) { name ->
            model.folder(name, null, dismiss)
        }
        null -> AlertDialog(
            onDismissRequest = close,
            title = { Text(stringResource(R.string.manage_folders)) },
            text = {
                Column(Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
                    if (library.folders.isEmpty()) Text(stringResource(R.string.no_folders))
                    library.folders.forEach { folder ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(folder.text("name").orEmpty(), Modifier.weight(1f))
                            ActionIcon(R.drawable.ic_edit, R.string.rename_folder) { action = "edit:${folder.id}" }
                            ActionIcon(R.drawable.ic_delete, R.string.delete_folder) { action = "delete:${folder.id}" }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { action = "new" }) { Text(stringResource(R.string.new_folder)) } },
            dismissButton = { TextButton(onClick = close) { Text(stringResource(R.string.close)) } },
        )
        else -> {
            val folder = library.folders.firstOrNull { it.id == dialog.substringAfter(":") }
            if (folder == null) {
                androidx.compose.runtime.LaunchedEffect(dialog) { dismiss() }
            } else if (dialog.startsWith("edit:")) {
                NameDialog(R.string.rename_folder, R.string.folder_name, folder.text("name").orEmpty(), dismiss) {
                    model.folder(it, folder, dismiss)
                }
            } else {
                Confirm(R.string.delete_folder, R.string.delete_folder_hint, R.string.delete, dismiss) {
                    model.remove(folder, dismiss)
                }
            }
        }
    }
}
