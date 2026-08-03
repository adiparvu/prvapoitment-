import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// The week schedule board.
///
/// A date strip pages through the seven days of the shown week; under it every
/// team member gets a row with their shifts for that day. Shift rows swipe to
/// delete and tap to edit, and managers get an inline add button per person.
/// Weeks are paged with the chevrons, which reloads only the schedule.
struct ShiftBoardView: View {
    let model: TeamModel
    /// Whether the session holds `.manageTeam`; read-only staff still see the
    /// board but cannot change it.
    let canManage: Bool
    let delete: (Shift) -> Void
    let retry: () -> Void

    var body: some View {
        @Bindable var model = model

        OperationsBlock(
            "Schedule",
            subtitle: OperationsFormat.rangeTitle(model.weekInterval)
        ) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                weekControls

                PRVDateStrip(
                    selection: $model.selectedDay,
                    startingFrom: model.weekStart,
                    days: 7
                )
                .padding(.horizontal, -PRVSpacing.md)

                daySummary

                if let scheduleError = model.scheduleError {
                    OperationsErrorCard(message: scheduleError, retry: retry)
                } else if model.members.isEmpty {
                    Text("Add team members to start building a rota.")
                        .prvStyle(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: PRVSpacing.sm) {
                        ForEach(model.members) { member in
                            memberRow(member)
                        }
                    }
                }
            }
            .prvGlassCard()
        }
        .prvAnimation(PRVMotion.spring, value: model.selectedDay)
        .prvAnimation(PRVMotion.spring, value: model.shifts)
    }

    // MARK: Week paging

    private var weekControls: some View {
        HStack(spacing: PRVSpacing.xs) {
            weekButton(systemImage: "chevron.left", label: "Previous week") {
                model.shiftWeek(by: -1)
            }

            Spacer(minLength: PRVSpacing.xs)

            if !model.isShowingCurrentWeek {
                Button("This week") {
                    PRVHaptics.tap()
                    model.goToCurrentWeek()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to the current week")
            }

            Spacer(minLength: PRVSpacing.xs)

            weekButton(systemImage: "chevron.right", label: "Next week") {
                model.shiftWeek(by: 1)
            }
        }
    }

    private func weekButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.prv.textPrimary)
                .frame(width: 32, height: 32)
                .prvGlassEffect(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Day summary

    private var daySummary: some View {
        HStack(spacing: PRVSpacing.xs) {
            Text(OperationsFormat.longDay(model.selectedDay))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)

            Spacer(minLength: PRVSpacing.xs)

            let dayShifts = model.shifts(on: model.selectedDay)
            PRVTag("\(dayShifts.count) shifts", systemImage: "person.2")
            PRVTag(
                OperationsFormat.duration(model.scheduledHours(on: model.selectedDay)),
                systemImage: "clock"
            )
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Member rows

    /// One person's line on the board. Built with `@ContentBuilder`: a header
    /// that branches on permission plus a nested `ForEach` of shift rows,
    /// instantiated once per team member, makes this the board's heaviest
    /// type-check site.
    @ContentBuilder
    private func memberRow(_ member: TeamMember) -> some View {
        let shifts = model.shifts(for: member.id, on: model.selectedDay)

        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(spacing: PRVSpacing.xs) {
                PRVAvatar(name: member.displayName, imageURL: member.photoURL, size: .small)
                Text(member.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: PRVSpacing.xs)

                if canManage {
                    Button {
                        model.addShift(for: member.id)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.prv.accent)
                            .frame(width: 28, height: 28)
                            .background(Color.prv.accent.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a shift for \(member.displayName) on \(OperationsFormat.longDay(model.selectedDay))")
                }
            }

            if shifts.isEmpty {
                Text("Not scheduled")
                    .prvStyle(.caption)
                    .padding(.leading, 36)
            } else {
                ForEach(shifts) { shift in
                    shiftRow(shift)
                }
            }
        }
        .padding(.vertical, PRVSpacing.xxs)
    }

    /// A shift on the board: tap to edit, swipe to remove.
    ///
    /// The row is a card in a `ScrollView` rather than a `List` row, and the
    /// enclosing desk carries `swipeActionsContainer()` — which is what lets it
    /// answer a swipe without the board surrendering its layout to a `List`.
    @ViewBuilder
    private func shiftRow(_ shift: Shift) -> some View {
        if canManage {
            shiftContent(shift, isEditable: true)
                .operationsRowSurface()
                .contentShape(Rectangle())
                .onTapGesture {
                    PRVHaptics.tap()
                    model.editShift(shift)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Double tap to edit this shift")
                .operationsDeleteAction("Delete shift") { delete(shift) }
                .opacity(isPending(shift) ? 0.5 : 1)
                .allowsHitTesting(!isPending(shift))
        } else {
            shiftContent(shift, isEditable: false)
                .padding(PRVSpacing.sm)
                .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.md))
        }
    }

    /// Whether a save or delete for this shift is already in flight, in which
    /// case the row dims and stops answering both taps and swipes.
    private func isPending(_ shift: Shift) -> Bool {
        model.pendingShiftIDs.contains(shift.id)
    }

    private func shiftContent(_ shift: Shift, isEditable: Bool) -> some View {
        HStack(spacing: PRVSpacing.xs) {
            Capsule()
                .fill(Color.prv.accentGradient)
                .frame(width: 4, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(OperationsFormat.window(shift.start, shift.end))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()

                if let note = shift.note, !note.isBlank {
                    Text(note)
                        .prvStyle(.caption)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: PRVSpacing.xs)

            Text(OperationsFormat.duration(shift.end.timeIntervalSince(shift.start)))
                .prvStyle(.caption)
                .monospacedDigit()

            if isEditable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.prv.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Shift \(OperationsFormat.window(shift.start, shift.end)), "
                + OperationsFormat.duration(shift.end.timeIntervalSince(shift.start))
                + ((shift.note?.isBlank == false) ? ", note: \(shift.note ?? "")" : "")
        )
    }
}

// MARK: - Editor sheet

/// Adds or edits a single shift: who, when, and an optional note.
///
/// The sheet validates locally — the end must come after the start — and warns
/// (without blocking) when the window overlaps another shift for the same
/// person, which is legitimate for split cover but usually a mistake.
struct ShiftEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let members: [TeamMember]
    /// Every shift already on the board, used for the overlap warning.
    let existingShifts: [Shift]
    let isSaving: Bool
    /// Persists the draft. Returns `true` when the sheet should close.
    let save: @MainActor (ShiftDraft) async -> Bool

    @State private var draft: ShiftDraft

    /// Creates the sheet for a draft produced by ``TeamModel``.
    init(
        draft: ShiftDraft,
        members: [TeamMember],
        existingShifts: [Shift],
        isSaving: Bool,
        save: @escaping @MainActor (ShiftDraft) async -> Bool
    ) {
        self.members = members
        self.existingShifts = existingShifts
        self.isSaving = isSaving
        self.save = save
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    if members.count > 1 {
                        PRVGlassCard {
                            Picker("Team member", selection: $draft.employeeID) {
                                ForEach(members) { member in
                                    Text(member.displayName).tag(member.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Color.prv.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Team member for this shift")
                        }
                    }

                    PRVGlassCard {
                        VStack(alignment: .leading, spacing: PRVSpacing.md) {
                            DatePicker(
                                "Starts",
                                selection: $draft.start,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            Divider()
                            DatePicker(
                                "Ends",
                                selection: $draft.end,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                        .tint(Color.prv.accent)
                        .font(.subheadline.weight(.medium))
                    }

                    PRVGlassCard {
                        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                            Text("Note")
                                .prvStyle(.footnote)
                            TextField("Front desk cover, training, …", text: $draft.note, axis: .vertical)
                                .lineLimit(1...3)
                                .font(.body)
                                .foregroundStyle(Color.prv.textPrimary)
                                .accessibilityLabel("Shift note")
                        }
                    }

                    summary
                }
                .padding(PRVSpacing.md)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(draft.isEditing ? "Edit Shift" : "New Shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .prvBottomBar {
                Button {
                    submit()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(draft.isEditing ? "Save Changes" : "Add Shift")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(isSaving || !draft.isValid)
                .accessibilityLabel(draft.isEditing ? "Save changes to this shift" : "Add this shift")
            }
            .onChange(of: draft.start) { _, newValue in
                // Keep the window sane: dragging the start past the end pushes
                // the end along rather than producing an invalid shift.
                if draft.end <= newValue {
                    draft.end = newValue.adding(minutes: 60)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            OperationsDetailRow(
                label: "Length",
                value: OperationsFormat.duration(draft.duration),
                systemImage: "clock"
            )
            OperationsDetailRow(
                label: "Day",
                value: OperationsFormat.longDay(draft.start),
                systemImage: "calendar"
            )

            if !draft.isValid {
                OperationsFootnote(
                    "A shift has to end after it starts.",
                    systemImage: "exclamationmark.triangle"
                )
            } else if hasOverlap {
                OperationsFootnote(
                    "This overlaps another shift for the same person. That's fine for split cover — just double-check it's intended.",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .prvGlassCard()
    }

    /// Whether the draft window collides with another shift for the same person.
    private var hasOverlap: Bool {
        existingShifts.contains { shift in
            shift.id != draft.shiftID
                && shift.employeeID == draft.employeeID
                && shift.start < draft.end
                && shift.end > draft.start
        }
    }

    private func submit() {
        guard draft.isValid, !isSaving else { return }
        PRVHaptics.impact()
        Task {
            if await save(draft) { dismiss() }
        }
    }
}

// MARK: - Previews

#Preview("Shift editor") {
    ShiftEditorSheet(
        draft: .new(employeeID: TeamPreviewFixtures.employee.id, day: .now),
        members: [TeamPreviewFixtures.member],
        existingShifts: [],
        isSaving: false,
        save: { _ in true }
    )
}
