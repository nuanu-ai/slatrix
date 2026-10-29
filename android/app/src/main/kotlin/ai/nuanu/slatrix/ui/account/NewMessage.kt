package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.PeopleSearchState
import ai.nuanu.slatrix.core.Person
import ai.nuanu.slatrix.core.RoomSummary
import androidx.compose.runtime.Composable

@Composable
fun NewMessageScreen(state: PeopleSearchState, recent: List<RoomSummary>, opening: String?, error: String?, onQuery: (String) -> Unit,
    onPerson: (Person) -> Unit, onRoom: (String) -> Unit, onBack: () -> Unit) {
}
