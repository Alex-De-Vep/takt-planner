package local.planner.android

import android.content.Intent
import android.net.Uri

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
internal fun ChatScreen(library: Library, model: PlannerModel, settings: () -> Unit) {
    val chat by model.chat.state.collectAsState()
    var prompt by remember { mutableStateOf("") }
    var taskId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectTask by rememberSaveable { mutableStateOf(false) }
    var applying by remember { mutableStateOf<String?>(null) }
    val task = library.tasks.firstOrNull { it.id == taskId }
    val focus = LocalFocusManager.current
    val openSettings = { focus.clearFocus(); settings() }
    val openTaskPicker = { focus.clearFocus(); selectTask = true }
    val send = { text: String ->
        model.chat.send(text.trim(), task, task?.let { library.items(it.id) }.orEmpty()) {
            if (prompt == text) prompt = ""
        }
    }
    ChatHeading(chat.activeModelLabel ?: chat.model.takeIf(String::isNotEmpty), openSettings)
    if (chat.model.isEmpty()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            EmptyPanel(R.drawable.ic_chat, R.string.chat_connect, R.string.chat_connect_hint)
            Button(onClick = openSettings) { Text(stringResource(R.string.chat_choose_model)) }
        }
        return
    }

    val scroll = rememberLazyListState()
    val entries = chat.lines.filter { it.text.isNotBlank() }
    val showStart = entries.isEmpty()
    val hasQuestions = chat.questions.isNotEmpty()
    LaunchedEffect(chat.lines, chat.proposals.size, chat.questions) {
        scroll.scrollToItem(0)
    }

    Column(Modifier.imePadding()) {
        LazyColumn(
            state = scroll, modifier = Modifier.weight(1f), reverseLayout = !showStart,
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp, if (showStart) Alignment.Top else Alignment.Bottom),
        ) {
            if (showStart) item {
                Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(stringResource(R.string.chat_start), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.chat_start_hint), style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            items(chat.proposals.asReversed(), key = ChatProposal::id) { proposal ->
                ProposalCard(proposal, applying == null, { model.chat.removeProposal(proposal.id) }) {
                    if (applying == null) {
                        applying = proposal.id
                        model.applyChatProposal(proposal, {
                            model.chat.removeProposal(proposal.id)
                            applying = null
                        }, { applying = null })
                    }
                }
            }
            if (hasQuestions) item {
                Column {
                    chat.questions.forEach { question ->
                        Text(question.text)
                        question.options.forEach { option ->
                            TextButton(onClick = { send(option) }, enabled = !chat.busy) { Text(option) }
                        }
                    }
                }
            }
            items(entries.asReversed()) { line ->
                Column(Modifier.fillMaxWidth()) {
                    Surface(
                        modifier = Modifier.align(if (line.role == "user") Alignment.End else Alignment.Start),
                        shape = MaterialTheme.shapes.large,
                        color = if (line.role == "user") MaterialTheme.colorScheme.primaryContainer
                            else MaterialTheme.colorScheme.surfaceContainerLow,
                    ) { Text(line.text, Modifier.padding(14.dp)) }
                }
            }
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {
            if (task != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = openTaskPicker, enabled = !chat.busy, modifier = Modifier.weight(1f, fill = false)) {
                        Text(task.text("title").orEmpty().ifBlank { stringResource(R.string.untitled) },
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    ActionIcon(R.drawable.ic_close, R.string.chat_remove_task) { taskId = null }
                }
            }
            if (chat.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            chat.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (task == null) {
                    IconButton(onClick = openTaskPicker, enabled = !chat.busy && library.tasks.isNotEmpty()) {
                        Glyph(R.drawable.ic_attach, stringResource(R.string.chat_attach_task), LocalContentColor.current)
                    }
                }
                val label = stringResource(R.string.chat_message)
                OutlinedTextField(prompt, { prompt = it.take(4000) }, Modifier.weight(1f).semantics { contentDescription = label },
                    placeholder = { Text(label) }, shape = MaterialTheme.shapes.extraLarge, maxLines = 3)
                FilledIconButton(onClick = { send(prompt) }, enabled = !chat.busy && prompt.isNotBlank()) {
                    Glyph(R.drawable.ic_send, stringResource(R.string.chat_send), LocalContentColor.current)
                }
            }
        }
    }
    if (selectTask) {
        var search by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { selectTask = false }, title = { Text(stringResource(R.string.chat_attach_task)) },
            text = {
                Column {
                    Text(stringResource(R.string.chat_context_hint))
                    OutlinedTextField(search, { search = it }, label = { Text(stringResource(R.string.search)) }, singleLine = true)
                    LazyColumn(Modifier.heightIn(max = 280.dp)) {
                        items(library.tasks.filter { it.text("title").orEmpty().contains(search.trim(), ignoreCase = true) },
                            key = Entity::id) { entry ->
                            Text(entry.text("title").orEmpty().ifBlank { stringResource(R.string.untitled) },
                                Modifier.fillMaxWidth().clickable { taskId = entry.id; selectTask = false }.padding(vertical = 12.dp))
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { selectTask = false }) { Text(stringResource(R.string.close)) } },
        )
    }
}

@Composable
private fun ChatHeading(activeModel: String?, settings: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.chat), style = MaterialTheme.typography.headlineSmall)
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            if (activeModel == null) {
                ActionIcon(R.drawable.ic_settings, R.string.chat_choose_model, onClick = settings)
            } else {
                TextButton(onClick = settings, contentPadding = PaddingValues(horizontal = 4.dp)) {
                    Text(activeModel, Modifier.weight(1f, fill = false), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Glyph(R.drawable.ic_chevron_down, tint = LocalContentColor.current)
                }
            }
        }
    }
}

@Composable
private fun ProposalCard(proposal: ChatProposal, available: Boolean, dismiss: () -> Unit, apply: () -> Unit) {
    Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val original = proposal.task
            Text(stringResource(if (original == null) R.string.new_task else R.string.chat_edit_task),
                style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            original?.text("title")?.let { Text(stringResource(R.string.chat_proposal_target, it)) }
            proposal.title?.let { Text(it, style = MaterialTheme.typography.titleMedium) }
            proposal.description?.let { Text(it.ifBlank { stringResource(R.string.chat_clear_description) }) }
            proposal.checklist.forEach { Text("• $it") }
            proposal.deadline?.let { Text(deadlineLabel(it)) }
            if (proposal.focused) Text(stringResource(R.string.show_in_today))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = apply, enabled = available) { Text(stringResource(R.string.chat_apply)) }
                TextButton(onClick = dismiss, enabled = available) { Text(stringResource(R.string.cancel)) }
            }
        }
    }
}

@Composable
internal fun ChatConnectionDialog(controller: ChatController, close: () -> Unit) {
    val state by controller.state.collectAsState()
    var editing by rememberSaveable { mutableStateOf<GatewayProvider?>(null) }
    val initialProvider = editing
    if (initialProvider != null) {
        ChatProviderDialog(controller, state, initialProvider) { editing = null }
        return
    }
    val unconnected = GatewayProvider.entries.firstOrNull { it !in state.profiles }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.chat_choose_model)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state.profiles.isEmpty()) {
                    if (!state.busy) Text(stringResource(R.string.chat_no_models))
                } else {
                    Text(stringResource(R.string.chat_connected_models), style = MaterialTheme.typography.titleSmall)
                    Column(Modifier.selectableGroup()) {
                        state.profiles.entries.sortedBy { it.key.label }.forEach { (provider, saved) ->
                            val active = provider == state.provider
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Row(
                                    Modifier.weight(1f).selectable(active, enabled = !state.busy, role = Role.RadioButton) {
                                        controller.activate(provider)
                                    }.padding(vertical = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    RadioButton(selected = active, onClick = null, enabled = !state.busy)
                                    Column {
                                        Text(saved.modelLabel, style = MaterialTheme.typography.titleSmall)
                                        Text(if (active) stringResource(R.string.chat_active_provider, provider.label) else provider.label,
                                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                                ActionIcon(R.drawable.ic_edit, R.string.chat_edit_connection, enabled = !state.busy) {
                                    controller.clearCandidate()
                                    editing = provider
                                }
                            }
                        }
                    }
                }
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            if (unconnected != null) TextButton(onClick = {
                controller.clearCandidate()
                editing = unconnected
            }, enabled = !state.busy) { Text(stringResource(R.string.chat_add_model)) }
        },
        dismissButton = { TextButton(onClick = close) { Text(stringResource(R.string.close)) } },
    )
}

@Composable
private fun ChatProviderDialog(controller: ChatController, state: ChatState, initialProvider: GatewayProvider, close: () -> Unit) {
    val context = LocalContext.current
    var provider by rememberSaveable { mutableStateOf(initialProvider) }
    val saved = state.profiles[provider]
    var address by rememberSaveable(provider) { mutableStateOf(saved?.address ?: provider.bases.firstOrNull().orEmpty()) }
    var key by remember(provider) { mutableStateOf("") }
    var project by rememberSaveable(provider) { mutableStateOf(saved?.project.orEmpty()) }
    var modelIds by rememberSaveable(provider) {
        mutableStateOf((saved?.models?.map(GatewayModel::id) ?: provider.configuredModels.orEmpty()).joinToString(", "))
    }
    var scope by rememberSaveable(provider) { mutableStateOf(saved?.scope ?: GigaScope.Personal) }
    var selectedId by rememberSaveable(provider) { mutableStateOf(saved?.model.orEmpty()) }
    var useTools by rememberSaveable(provider) { mutableStateOf(saved?.tools ?: false) }
    val hasCandidate = state.candidateProvider == provider
    val changed = saved != null && (key.isNotBlank() || address != saved.address ||
        project != saved.project.orEmpty() || scope != (saved.scope ?: GigaScope.Personal) ||
        (provider.configuredModels?.isNotEmpty() == true && modelIds != saved.models.joinToString(", ", transform = GatewayModel::id)))
    val catalog = when {
        hasCandidate -> state.catalog
        changed -> emptyList()
        else -> saved?.models.orEmpty()
    }
    val selected = catalog.firstOrNull { it.id == selectedId } ?: catalog.firstOrNull()
    val canSetTools = selected?.tools != false
    val dismiss = {
        when {
            state.authorizing -> controller.cancelAuthorization()
            !state.busy -> { controller.clearCandidate(); close() }
        }
    }
    LaunchedEffect(provider, selected?.id, hasCandidate) {
        if (selected != null) useTools = if (selected.id == saved?.model) saved.tools else selected.tools == true
    }
    val openBrowser: (String) -> Unit = { address ->
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(address)))
    }
    AlertDialog(
        onDismissRequest = dismiss, title = { Text(stringResource(R.string.chat_connection)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                GatewayPicker(stringResource(R.string.chat_provider), GatewayProvider.entries, provider, !state.busy, { it.label }) {
                    controller.clearCandidate()
                    provider = it
                }
                when (provider) {
                    GatewayProvider.ChatGPT -> Text(stringResource(R.string.chat_chatgpt_hint))
                    GatewayProvider.Copilot -> Text(stringResource(R.string.chat_copilot_hint))
                    GatewayProvider.LiteLLM -> Text(stringResource(R.string.chat_litellm_hint))
                    GatewayProvider.GigaChat -> Text(stringResource(R.string.chat_giga_hint))
                    else -> Text(stringResource(R.string.chat_connect_hint))
                }
                if (provider.bases.isEmpty()) {
                    OutlinedTextField(address, { address = it; controller.clearCandidate() }, enabled = !state.busy,
                        label = { Text(stringResource(R.string.chat_gateway_address)) }, singleLine = true)
                } else if (provider.bases.size > 1) {
                    GatewayPicker(stringResource(R.string.chat_endpoint), provider.bases, address, !state.busy, {
                        runCatching { java.net.URI(it).host }.getOrNull() ?: it
                    }) { address = it; controller.clearCandidate() }
                }
                if (provider == GatewayProvider.ChatGPT || provider == GatewayProvider.OpenRouter) {
                    TextButton(onClick = { controller.authorize(provider, openBrowser) }, enabled = !state.busy) {
                        Text(stringResource(R.string.chat_browser_login, provider.label))
                    }
                }
                if (provider != GatewayProvider.ChatGPT) {
                    OutlinedTextField(key, { key = it; controller.clearCandidate() }, enabled = !state.busy,
                        label = { Text(stringResource(if (provider.bases.isEmpty()) R.string.chat_gateway_key else R.string.chat_api_key)) },
                        singleLine = true, visualTransformation = PasswordVisualTransformation(),
                        supportingText = if (saved != null) ({ Text(stringResource(R.string.chat_existing_key)) }) else null)
                    if (provider == GatewayProvider.Yandex) {
                        OutlinedTextField(project, { project = it; controller.clearCandidate() }, enabled = !state.busy,
                            label = { Text(stringResource(R.string.chat_yandex_project)) }, singleLine = true)
                    }
                    if (provider.configuredModels?.isNotEmpty() == true) {
                        OutlinedTextField(modelIds, { modelIds = it; controller.clearCandidate() }, enabled = !state.busy,
                            label = { Text(stringResource(R.string.chat_model_ids)) }, maxLines = 3)
                    }
                    if (provider == GatewayProvider.GigaChat) {
                        val labels = GigaScope.entries.associateWith { stringResource(it.label) }
                        GatewayPicker(stringResource(R.string.chat_giga_scope), GigaScope.entries, scope, !state.busy, { labels.getValue(it) }) {
                            scope = it
                            controller.clearCandidate()
                        }
                    }
                    TextButton(
                        onClick = { controller.loadModels(provider, address, key, GatewayOptions(modelIds, project, scope)) },
                        enabled = !state.busy && (provider.bases.isNotEmpty() || address.isNotBlank()),
                    ) { Text(stringResource(R.string.chat_load_models)) }
                }
                if (selected != null) {
                    GatewayPicker(stringResource(R.string.chat_model), catalog, selected, !state.busy, GatewayModel::label) {
                        selectedId = it.id
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(useTools && canSetTools, { useTools = it }, enabled = canSetTools && !state.busy)
                        Text(stringResource(R.string.chat_task_proposals))
                    }
                } else if (saved != null) {
                    Text(stringResource(R.string.chat_current_model, saved.model))
                }
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                if (saved != null) {
                    TextButton(onClick = { key = ""; controller.disconnect(provider) }, enabled = !state.busy) {
                        Text(stringResource(R.string.chat_disconnect))
                    }
                }
            }
        },
        confirmButton = {
            val canActivate = saved != null && !changed && provider != state.provider
            TextButton(onClick = {
                if (selected != null) controller.connect(provider, selected, useTools, close)
                else controller.activate(provider)
                key = ""
            }, enabled = !state.busy && (selected != null || canActivate)) {
                Text(stringResource(when {
                    selected == null -> R.string.chat_use_provider
                    saved == null -> R.string.chat_add_model
                    else -> R.string.save
                }))
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
