import SwiftUI

struct InventoryListView: View {
    @StateObject private var store = SurveyStore()
    @State private var showNew = false
    @State private var newName = ""
    @State private var openedID: UUID?

    var body: some View {
        List {
            if store.surveys.isEmpty {
                Text("Brak inwentaryzacji. Utwórz nową przyciskiem +.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.surveys) { survey in
                NavigationLink {
                    SurveyView(store: store, surveyID: survey.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(survey.name).bold()
                        Text("\(survey.points.count) pkt · \(survey.pipes.count) odc. · \(survey.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { store.surveys[$0] }
                toDelete.forEach(store.delete)
            }
        }
        .navigationTitle("Inwentaryzacja")
        .navigationDestination(item: $openedID) { id in
            SurveyView(store: store, surveyID: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    showNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Nowa inwentaryzacja", isPresented: $showNew) {
            TextField("Nazwa, np. ul. Polna – kanalizacja", text: $newName)
            Button("Anuluj", role: .cancel) {}
            Button("Utwórz") {
                let survey = store.create(name: newName)
                openedID = survey.id
            }
        }
    }
}
