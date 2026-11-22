import SwiftUI

struct PipeEditorView: View {
    let survey: Survey
    let onSave: (PipeSegment) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pipe: PipeSegment
    @State private var isNew: Bool

    init(survey: Survey, pipe: PipeSegment?, onSave: @escaping (PipeSegment) -> Void) {
        self.survey = survey
        self.onSave = onSave
        if let pipe {
            _pipe = State(initialValue: pipe)
            _isNew = State(initialValue: false)
        } else {
            let points = survey.points
            let from = points.count >= 2 ? points[points.count - 2].id : (points.first?.id ?? UUID())
            let to = points.last?.id ?? UUID()
            let lastNetwork = survey.pipes.last?.network ?? .sanitarna
            let lastDiameter = survey.pipes.last?.diameter ?? ""
            let lastMaterial = survey.pipes.last?.material ?? ""
            _pipe = State(initialValue: PipeSegment(fromID: from, toID: to, network: lastNetwork,
                                                    diameter: lastDiameter, material: lastMaterial))
            _isNew = State(initialValue: true)
        }
    }

    private var lengthText: String {
        guard let length = survey.length(of: pipe) else { return "—" }
        return String(format: "%.2f m", length)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Odcinek") {
                    Picker("Od punktu", selection: $pipe.fromID) {
                        ForEach(survey.points) { p in
                            Text("\(p.number) – \(p.kind.name)").tag(p.id)
                        }
                    }
                    Picker("Do punktu", selection: $pipe.toID) {
                        ForEach(survey.points) { p in
                            Text("\(p.number) – \(p.kind.name)").tag(p.id)
                        }
                    }
                    LabeledContent("Długość (rzut)", value: lengthText)
                }
                Section("Sieć") {
                    Picker("Rodzaj sieci", selection: $pipe.network) {
                        ForEach(NetworkKind.allCases) { n in
                            Text("\(n.code) – \(n.name)").tag(n)
                        }
                    }
                    LabeledContent("Średnica") {
                        TextField("np. DN200", text: $pipe.diameter)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Materiał") {
                        TextField("np. PVC", text: $pipe.material)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Opis / uwagi", text: $pipe.note, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(isNew ? "Nowy odcinek" : "Odcinek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        onSave(pipe)
                        dismiss()
                    }
                    .disabled(pipe.fromID == pipe.toID
                              || survey.point(pipe.fromID) == nil
                              || survey.point(pipe.toID) == nil)
                }
            }
        }
    }
}
