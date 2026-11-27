package local.planner.android

import android.content.Intent
import android.net.Uri

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
internal fun ChatModelDialog(controller: ChatController, close: () -> Unit) {
    ModelSelectionDialog(controller, forTranscription = false, close = close)
}

@Composable
internal fun TranscriptionModelDialog(
    controller: ChatController, manage: (() -> Unit)? = null, chosen: (TranscriptionSelection) -> Unit = {},
    close: () -> Unit,
) {
    ModelSelectionDialog(controller, forTranscription = true, manage = manage, chosen = chosen, close = close)
}

@Composable
private fun ModelSelectionDialog(
    controller: ChatController, forTranscription: Boolean,
    manage: (() -> Unit)? = null, chosen: (TranscriptionSelection) -> Unit = {}, close: () -> Unit,
) {
    val state by controller.state.collectAsState()
    var search by rememberSaveable { mutableStateOf("") }
    val profiles = state.profiles.entries.filter { it.value.authorized && it.value.visibleModels.isNotEmpty() }
        .sortedBy { it.key.label }
    val term = search.trim()
    val groups = profiles.map { (provider, saved) ->
        Triple(provider, saved, saved.visibleModels.filter { it.label.contains(term, true) || it.id.contains(term, true) })
    }.filter { (_, _, matches) -> matches.isNotEmpty() }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(if (forTranscription) R.string.voice_model else R.string.chat_choose_model)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (profiles.isNotEmpty()) PlannerTextField(search, { search = it }, placeholder = R.string.search, singleLine = true)
                if (groups.isEmpty() && !state.busy) {
                    Text(stringResource(if (profiles.isEmpty()) R.string.chat_no_visible_models else R.string.chat_no_matching_models))
                }
                LazyColumn(Modifier.heightIn(max = 360.dp).selectableGroup()) {
                    groups.forEach { (provider, saved, models) ->
                        item(key = provider.name) {
                            Text(provider.label, Modifier.padding(top = 8.dp), style = MaterialTheme.typography.titleSmall)
                        }
                        items(models, key = { provider.name + ":" + it.id }) { model ->
                            val compatible = if (forTranscription) {
                                provider in transcriptionProviders && saved.speechModels.any { it.id == model.id }
                            } else saved.models.any { it.id == model.id }
                            val active = if (forTranscription) {
                                state.transcription?.let { it.provider == provider && it.id == model.id } == true
                            } else provider == state.provider && model.id == state.model
                            val enabled = !state.busy && compatible
                            Row(
                                Modifier.fillMaxWidth().selectable(active, enabled = enabled, role = Role.RadioButton) {
                                    if (forTranscription) {
                                        controller.selectTranscription(provider, model) {
                                            controller.state.value.transcription?.let(chosen)
                                            close()
                                        }
                                    } else controller.selectModel(provider, model.id, close)
                                }.padding(vertical = 10.dp),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                RadioButton(selected = active, onClick = null, enabled = enabled)
                                Column {
                                    Text(model.label)
                                    if (!compatible) Text(stringResource(
                                        if (forTranscription) R.string.chat_model_chat_only else R.string.chat_model_speech_only),
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton(onClick = close) { Text(stringResource(R.string.close)) } },
        dismissButton = {
            if (manage != null) TextButton(onClick = manage, enabled = !state.busy) {
                Text(stringResource(R.string.chat_connection))
            }
        },
    )
}

@Composable
internal fun ChatConnectionDialog(controller: ChatController, close: () -> Unit) {
    val state by controller.state.collectAsState()
    var connecting by rememberSaveable { mutableStateOf<GatewayProvider?>(null) }
    var removing by rememberSaveable { mutableStateOf<GatewayProvider?>(null) }
    var choosingProvider by rememberSaveable { mutableStateOf(false) }
    var visibility by rememberSaveable { mutableStateOf(false) }
    connecting?.let { provider ->
        ChatProviderDialog(controller, state, provider) { connecting = null }
        return
    }
    removing?.let { provider ->
        RemoveProviderDialog(controller, state, provider) { removing = null }
        return
    }
    if (visibility) {
        VisibleModelsDialog(controller, state) { visibility = false }
        return
    }
    val available = GatewayProvider.entries.filterNot { it in state.profiles }.sortedBy { it.label }
    if (choosingProvider) {
        ChooseProviderDialog(available, close = { choosingProvider = false }) { provider ->
            choosingProvider = false
            controller.clearMessage()
            connecting = provider
        }
        return
    }
    val connected = state.profiles.entries.sortedBy { it.key.label }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.chat_connection)) },
        text = {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(onClick = { choosingProvider = true }, enabled = !state.busy && available.isNotEmpty()) {
                    Text(stringResource(R.string.chat_connect_provider))
                }
                if (connected.isEmpty() && !state.busy) {
                    Text(stringResource(R.string.chat_no_providers))
                } else if (connected.isNotEmpty()) {
                    Text(stringResource(R.string.chat_connected_providers), style = MaterialTheme.typography.titleSmall)
                    connected.forEach { (provider, saved) ->
                        val status = when {
                            saved.needsConsent -> R.string.chat_plan_consent_required
                            !saved.authorized -> R.string.chat_sign_in_required
                            saved.allModels.isEmpty() -> R.string.chat_models_not_loaded
                            else -> R.string.chat_provider_connected
                        }
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = MaterialTheme.shapes.medium,
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                        ) {
                            Row(
                                Modifier.padding(start = 12.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(provider.label, style = MaterialTheme.typography.titleSmall)
                                    Text(stringResource(status), style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    if (provider == GatewayProvider.ChatGPT && (!saved.authorized || saved.needsConsent)) {
                                        TextButton(onClick = {
                                            controller.clearMessage()
                                            connecting = provider
                                        }, enabled = !state.busy) {
                                            Text(stringResource(if (saved.needsConsent) R.string.chat_enable_plan
                                                else R.string.chat_sign_in_again))
                                        }
                                    }
                                }
                                ActionIcon(R.drawable.ic_delete, R.string.chat_disconnect, enabled = !state.busy) {
                                    controller.clearMessage()
                                    removing = provider
                                }
                            }
                        }
                    }
                    OutlinedButton(
                        onClick = {
                            controller.refreshModelCatalogs()
                            visibility = true
                        },
                        enabled = !state.busy && connected.any { it.value.authorized },
                    ) { Text(stringResource(R.string.chat_visible_models)) }
                }
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton(onClick = close) { Text(stringResource(R.string.close)) } },
    )
}

@Composable
private fun ChooseProviderDialog(
    providers: List<GatewayProvider>, close: () -> Unit, choose: (GatewayProvider) -> Unit,
) {
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.chat_choose_provider)) },
        text = {
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 360.dp)) {
                items(providers, key = { it.name }) { provider ->
                    DropdownMenuItem(text = { Text(provider.label) }, onClick = { choose(provider) })
                }
            }
        },
        confirmButton = { TextButton(onClick = close) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun RemoveProviderDialog(
    controller: ChatController, state: ChatState, provider: GatewayProvider, close: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!state.busy) close() },
        title = { Text(stringResource(R.string.chat_disconnect_title, provider.label)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.chat_disconnect_warning))
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { controller.disconnect(provider, close) },
                enabled = !state.busy,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) { Text(stringResource(R.string.delete)) }
        },
        dismissButton = { TextButton(onClick = close, enabled = !state.busy) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun ConfiguredModelsDialog(
    controller: ChatController, state: ChatState, provider: GatewayProvider, close: () -> Unit,
) {
    val saved = state.profiles[provider]
    var ids by rememberSaveable(provider) {
        mutableStateOf(saved?.models.orEmpty().map(GatewayModel::id)
            .ifEmpty { provider.configuredModels.orEmpty() }.joinToString(", "))
    }
    AlertDialog(
        onDismissRequest = { if (!state.busy) close() },
        title = { Text(stringResource(R.string.chat_provider_models, provider.label)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PlannerTextField(ids, { ids = it }, enabled = !state.busy,
                    placeholder = R.string.chat_model_ids, maxLines = 4)
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(onClick = { controller.saveConfiguredModels(provider, ids, close) },
                enabled = !state.busy && ids.isNotBlank()) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = close, enabled = !state.busy) { Text(stringResource(R.string.back)) } },
    )
}

@Composable
private fun VisibleModelsDialog(controller: ChatController, state: ChatState, close: () -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    var edits by rememberSaveable { mutableStateOf(arrayListOf<String>()) }
    val toggled = edits.toSet()
    var configuring by rememberSaveable { mutableStateOf<GatewayProvider?>(null) }
    configuring?.let { provider ->
        ConfiguredModelsDialog(controller, state, provider) { configuring = null }
        return
    }
    var addSpeech by rememberSaveable { mutableStateOf(false) }
    if (addSpeech) {
        var id by rememberSaveable { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { if (!state.busy) addSpeech = false },
            title = { Text(stringResource(R.string.voice_add_litellm_model)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    PlannerTextField(id, { id = it }, enabled = !state.busy,
                        placeholder = R.string.voice_manual_model, singleLine = true)
                    if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                    state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                }
            },
            confirmButton = {
                TextButton(onClick = { controller.addLiteLlmSpeechModel(id) { addSpeech = false } },
                    enabled = !state.busy && validTranscriptionModel(id.trim())) { Text(stringResource(R.string.voice_add_model_action)) }
            },
            dismissButton = {
                TextButton(onClick = { addSpeech = false }, enabled = !state.busy) { Text(stringResource(R.string.back)) }
            },
        )
        return
    }
    val term = search.trim()
    val groups = state.profiles.entries.filter { it.value.authorized }.sortedBy { it.key.label }.map { (provider, saved) ->
        Triple(provider, saved.hiddenModelIds, saved.allModels.filter { it.label.contains(term, true) || it.id.contains(term, true) })
    }.filter { (_, _, models) -> models.isNotEmpty() || term.isEmpty() }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.chat_visible_models)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PlannerTextField(search, { search = it }, placeholder = R.string.search, singleLine = true)
                LazyColumn(Modifier.heightIn(max = 360.dp)) {
                    groups.forEach { (provider, hidden, models) ->
                        item(key = provider.name) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(provider.label, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                                if (!provider.configuredModels.isNullOrEmpty()) {
                                    TextButton(onClick = { controller.clearMessage(); configuring = provider },
                                        enabled = !state.busy) {
                                        Text(stringResource(R.string.chat_edit_model_ids))
                                    }
                                }
                            }
                            if (models.isEmpty()) Text(stringResource(R.string.chat_models_not_loaded))
                        }
                        items(models, key = { provider.name + ":" + it.id }) { model ->
                            val key = provider.name + ":" + model.id
                            val checked = (model.id !in hidden) != (key in toggled)
                            Row(
                                Modifier.fillMaxWidth().toggleable(checked, enabled = !state.busy, role = Role.Checkbox) {
                                    edits = ArrayList(if (key in toggled) toggled - key else toggled + key)
                                }.padding(vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Checkbox(checked, onCheckedChange = null, enabled = !state.busy)
                                Text(model.label)
                            }
                        }
                    }
                }
                if (groups.isEmpty() && !state.busy) Text(stringResource(R.string.chat_no_matching_models))
                if (state.profiles[GatewayProvider.LiteLLM]?.authorized == true) {
                    TextButton(onClick = { controller.clearMessage(); addSpeech = true }, enabled = !state.busy) {
                        Text(stringResource(R.string.voice_add_litellm_model))
                    }
                }
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val changes = edits.groupBy(
                    keySelector = { GatewayProvider.valueOf(it.substringBefore(':')) },
                    valueTransform = { it.substringAfter(':') },
                ).mapValues { it.value.toSet() }
                controller.toggleVisibleModels(changes, close)
            }, enabled = !state.busy && edits.isNotEmpty()) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = close) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun ChatProviderDialog(
    controller: ChatController, state: ChatState, provider: GatewayProvider, close: () -> Unit,
) {
    val context = LocalContext.current
    val saved = state.profiles[provider]
    var address by rememberSaveable(provider) { mutableStateOf(provider.bases.firstOrNull().orEmpty()) }
    var key by remember(provider) { mutableStateOf("") }
    var project by rememberSaveable(provider) { mutableStateOf("") }
    var scope by rememberSaveable(provider) { mutableStateOf(GigaScope.Personal) }
    val canConnect = key.isNotBlank() &&
        (provider.bases.isNotEmpty() || address.isNotBlank()) &&
        (provider != GatewayProvider.Yandex || project.isNotBlank())
    val dismiss = {
        when {
            state.authorizing -> controller.cancelAuthorization()
            !state.busy -> { controller.clearMessage(); close() }
        }
    }
    val openBrowser: (String) -> Unit = {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it)))
    }
    val browserLogin = provider == GatewayProvider.ChatGPT || provider == GatewayProvider.OpenRouter
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(provider.label) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(when (provider) {
                    GatewayProvider.ChatGPT -> R.string.chat_chatgpt_hint
                    GatewayProvider.Copilot -> R.string.chat_copilot_hint
                    GatewayProvider.LiteLLM -> R.string.chat_litellm_hint
                    GatewayProvider.GigaChat -> R.string.chat_giga_hint
                    GatewayProvider.OpenRouter -> R.string.chat_openrouter_hint
                    else -> R.string.chat_connect_hint
                }))
                if (provider.bases.isEmpty()) {
                    PlannerTextField(address, { address = it; controller.clearMessage() }, enabled = !state.busy,
                        placeholder = R.string.chat_gateway_address, singleLine = true)
                } else if (provider.bases.size > 1) {
                    GatewayPicker(stringResource(R.string.chat_endpoint), provider.bases, address, !state.busy, {
                        runCatching { java.net.URI(it).host }.getOrNull() ?: it
                    }) { address = it; controller.clearMessage() }
                }
                if (provider != GatewayProvider.ChatGPT) {
                    PlannerTextField(key, { key = it; controller.clearMessage() }, enabled = !state.busy,
                        placeholder = if (provider.bases.isEmpty()) R.string.chat_gateway_key else R.string.chat_api_key,
                        singleLine = true, visualTransformation = PasswordVisualTransformation())
                }
                if (provider == GatewayProvider.Yandex) {
                    PlannerTextField(project, { project = it; controller.clearMessage() }, enabled = !state.busy,
                        placeholder = R.string.chat_yandex_project, singleLine = true)
                }
                if (provider == GatewayProvider.GigaChat) {
                    val labels = GigaScope.entries.associateWith { stringResource(it.label) }
                    GatewayPicker(stringResource(R.string.chat_giga_scope), GigaScope.entries, scope, !state.busy, { labels.getValue(it) }) {
                        scope = it
                        controller.clearMessage()
                    }
                }
                if (saved?.needsConsent == true) Text(stringResource(R.string.chat_plan_consent_required))
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            if (browserLogin && (provider == GatewayProvider.ChatGPT || key.isBlank())) {
                TextButton(onClick = { controller.authorize(provider, openBrowser, close) }, enabled = !state.busy) {
                    Text(when {
                        saved?.needsConsent == true -> stringResource(R.string.chat_enable_plan)
                        saved?.authorized == true -> stringResource(R.string.chat_sign_in_again)
                        else -> stringResource(R.string.chat_browser_login, provider.label)
                    })
                }
            } else {
                TextButton(onClick = { controller.connect(provider, address, key, project, scope, close) },
                    enabled = !state.busy && canConnect) {
                    Text(stringResource(R.string.chat_connect_action))
                }
            }
        },
        dismissButton = {
            TextButton(onClick = dismiss, enabled = !state.busy || state.authorizing) {
                Text(stringResource(if (state.authorizing) R.string.cancel else R.string.back))
            }
        },
    )
}

@Composable
private fun <T> GatewayPicker(
    label: String, options: List<T>, selected: T, enabled: Boolean, name: (T) -> String, choose: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = { expanded = true }, enabled = enabled) {
            Text(name(selected), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }, modifier = Modifier.heightIn(max = 360.dp)) {
            options.forEach { item ->
                DropdownMenuItem(text = { Text(name(item)) }, onClick = { choose(item); expanded = false })
            }
        }
    }
}
