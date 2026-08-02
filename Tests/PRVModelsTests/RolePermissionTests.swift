import Foundation
import PRVModels
import Testing

@Suite("Roles & permissions")
struct RolePermissionTests {
    @Test("Salon roles form a strict permission hierarchy: owner ⊇ manager ⊇ employee")
    func salonHierarchyIsAStrictSuperset() {
        let employee = UserRole.salonEmployee.permissions
        let manager = UserRole.salonManager.permissions
        let owner = UserRole.salonOwner.permissions

        #expect(manager.isSuperset(of: employee))
        #expect(owner.isSuperset(of: manager))
        #expect(owner.isSuperset(of: employee))

        // Strict: each step up genuinely adds capability.
        #expect(manager != employee)
        #expect(owner != manager)
        #expect(manager.isStrictSuperset(of: employee))
        #expect(owner.isStrictSuperset(of: manager))
    }

    @Test("Multi-salon roles extend the owner set with cross-location powers")
    func multiSalonExtendsOwner() {
        let owner = UserRole.salonOwner.permissions

        #expect(UserRole.multiSalonOwner.permissions.isStrictSuperset(of: owner))
        #expect(UserRole.regionalManager.permissions.isStrictSuperset(of: owner))
        #expect(UserRole.multiSalonOwner.permissions.contains(.manageMultipleLocations))
        #expect(UserRole.multiSalonOwner.permissions.contains(.compareLocations))
        #expect(!owner.contains(.manageMultipleLocations))
    }

    @Test("Premium clients extend the client set with priority booking")
    func premiumClientExtendsClient() {
        let client = UserRole.client.permissions
        let premium = UserRole.premiumClient.permissions

        #expect(premium.isStrictSuperset(of: client))
        #expect(premium.subtracting(client) == [.priorityBooking])
        #expect(client.isStrictSuperset(of: UserRole.guest.permissions))
    }

    @Test("Only staff-facing roles are business roles")
    func businessRolesAreCorrectlyClassified() {
        #expect(!UserRole.guest.isBusinessRole)
        #expect(!UserRole.client.isBusinessRole)
        #expect(!UserRole.premiumClient.isBusinessRole)
        #expect(UserRole.freelancer.isBusinessRole)
        #expect(UserRole.salonEmployee.isBusinessRole)
        #expect(UserRole.salonOwner.isBusinessRole)
        #expect(UserRole.superAdmin.isBusinessRole)
    }

    @Test("Administrators hold everything except developer tools; super admins hold everything")
    func adminScopesAreDistinct() {
        let administrator = UserRole.administrator.permissions

        #expect(administrator == Set(Permission.allCases).subtracting([.developerTools]))
        #expect(!administrator.contains(.developerTools))
        #expect(UserRole.superAdmin.permissions == Set(Permission.allCases))
        #expect(UserRole.developer.permissions.contains(.developerTools))
    }

    @Test("Narrow back-office roles stay narrow")
    func backOfficeRolesAreScoped() {
        #expect(UserRole.marketing.permissions == [.viewReports, .manageMarketing])
        #expect(!UserRole.marketing.permissions.contains(.manageSalon))
        #expect(UserRole.finance.permissions.contains(.manageRefunds))
        #expect(!UserRole.finance.permissions.contains(.book))
        #expect(UserRole.support.permissions.contains(.moderateReviews))
        #expect(!UserRole.support.permissions.contains(.manageFinance))
    }

    @Test("Permission checks read through the user's role")
    func userChecksItsRolePermissions() {
        let client = User(role: .premiumClient, firstName: "Sofia", lastName: "Laurent", email: "sofia@example.com")
        let owner = User(role: .salonOwner, firstName: "Emma", lastName: "Verhoeven", email: "emma@example.com")

        #expect(client.can(.book))
        #expect(client.can(.priorityBooking))
        #expect(!client.can(.manageInventory))
        #expect(owner.can(.manageInventory))
        #expect(owner.can(.configurePrepayment))
        #expect(!owner.can(.developerTools))
    }

    @Test("Display helpers never come back empty and initials are derived from the name")
    func displayHelpersAreUsable() {
        let user = User(role: .client, firstName: "Sofia", lastName: "Laurent", email: "sofia@example.com")

        #expect(user.fullName == "Sofia Laurent")
        #expect(user.initials == "SL")
        #expect(user.preferredLanguage == "en")
        #expect(user.salonIDs.isEmpty)
        #expect(UserRole.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(UserRole.salonEmployee.rawValue == "salon_employee")
    }
}
