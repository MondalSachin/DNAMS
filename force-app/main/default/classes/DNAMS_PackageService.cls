/**
 * Package lifecycle rules for DNAMS_Package__c and the files attached to its elements.
 *  - Every package gets a random Upload Token (the secret in the dealer upload link).
 *  - Package Name is derived from dealer codes and type.
 *  - Status -> Initiated creates the package's own elements from the active DNAMS_Element_Type__c records.
 *  - Status -> Dealer Submitted checks required elements have documents and assigns the CENTRAL RMR queue.
 *  - Documents on elements are locked once the package leaves an editable status.
 *  - Guest uploads (ContentVersion.DNAMS_Upload_Token_fileupload__c = "elementId:token") are validated
 *    and linked to the element.
 * Runs without sharing and with explicit SYSTEM_MODE queries/DML: these are integrity rules and must see every
 * element and file link whoever performs the save; for the site guest, "without sharing" alone returns no rows.
 */
public without sharing class DNAMS_PackageService {
    public static final String STATUS_DRAFT = 'Draft';
    public static final String STATUS_INITIATED = 'Initiated';
    public static final String STATUS_DEALER_SUBMITTED = 'Dealer Submitted';
    public static final String STATUS_RETURNED = 'Returned';
    public static final Set<String> EDITABLE_STATUSES = new Set<String>{
        STATUS_DRAFT,
        STATUS_INITIATED,
        STATUS_RETURNED
    };
    public static final String CENTRAL_RMR_QUEUE = 'CENTRAL_RMR';
    public static final String LOCKED_MESSAGE = 'Documents cannot be changed after the package is submitted.';
    public static final String INVALID_UPLOAD_MESSAGE = 'This upload link is not valid.';
    public static final String SUBMIT_FROM_MESSAGE = 'A package can only be submitted from Initiated or Returned.';
    public static final Set<String> SUBMITTABLE_FROM = new Set<String>{ STATUS_INITIATED, STATUS_RETURNED };

    // ------------------------------------------------------------------ Package trigger entry points

    public static void beforeSave(List<DNAMS_Package__c> packages, Map<Id, DNAMS_Package__c> oldById) {
        if (oldById == null) {
            for (DNAMS_Package__c pkg : packages) {
                pkg.Upload_Token__c = newUploadToken();
            }
        }
        setPackageNames(packages, oldById);

        List<DNAMS_Package__c> submitted = new List<DNAMS_Package__c>();
        List<DNAMS_Package__c> firstSubmits = new List<DNAMS_Package__c>();
        for (DNAMS_Package__c pkg : packages) {
            if (!statusChangedTo(pkg, oldById, STATUS_DEALER_SUBMITTED)) {
                continue;
            }
            String previous = oldById == null ? null : oldById.get(pkg.Id).Status__c;
            if (previous != null && !SUBMITTABLE_FROM.contains(previous)) {
                pkg.addError(SUBMIT_FROM_MESSAGE);
                continue;
            }
            submitted.add(pkg);
            // Resubmits (Returned -> Dealer Submitted) keep the RMR user who owns the package.
            if (previous != STATUS_RETURNED) {
                firstSubmits.add(pkg);
            }
        }
        if (!submitted.isEmpty()) {
            validateRequiredDocuments(submitted);
            assignCentralRmrQueue(firstSubmits);
        }
    }

    public static void afterSave(List<DNAMS_Package__c> packages, Map<Id, DNAMS_Package__c> oldById) {
        List<DNAMS_Package__c> initiated = new List<DNAMS_Package__c>();
        List<DNAMS_Package_Review_Requested__e> reviewRequests = new List<DNAMS_Package_Review_Requested__e>();
        for (DNAMS_Package__c pkg : packages) {
            if (statusChangedTo(pkg, oldById, STATUS_INITIATED)) {
                initiated.add(pkg);
            }
            // Step 2: only Initiated -> Dealer Submitted or Returned -> Dealer Submitted start the AI review.
            String previous = oldById == null ? null : oldById.get(pkg.Id).Status__c;
            if (statusChangedTo(pkg, oldById, STATUS_DEALER_SUBMITTED) && SUBMITTABLE_FROM.contains(previous)) {
                reviewRequests.add(
                    new DNAMS_Package_Review_Requested__e(
                        Package_Id__c = pkg.Id,
                        Trigger_Source__c = previous == STATUS_RETURNED
                            ? DNAMS_PackageReviewPipelineService.SOURCE_DEALER_RESUBMIT
                            : DNAMS_PackageReviewPipelineService.SOURCE_DEALER_SUBMIT,
                        Requested_By_Id__c = UserInfo.getUserId()
                    )
                );
            }
        }
        if (!initiated.isEmpty()) {
            createElements(initiated);
        }
        if (!reviewRequests.isEmpty()) {
            // Published after commit; the subscriber runs as the configured pipeline user, not the site guest.
            EventBus.publish(reviewRequests);
        }
    }

    // ------------------------------------------------------------------ File trigger entry points

    /** Blocks new files on elements of packages that are no longer editable. */
    public static void blockLockedLinks(List<ContentDocumentLink> links) {
        Set<Id> elementIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            if (isElementId(link.LinkedEntityId)) {
                elementIds.add(link.LinkedEntityId);
            }
        }
        if (elementIds.isEmpty()) {
            return;
        }
        Set<Id> lockedElementIds = lockedElementIds(elementIds);
        for (ContentDocumentLink link : links) {
            if (lockedElementIds.contains(link.LinkedEntityId)) {
                link.addError(LOCKED_MESSAGE);
            }
        }
    }

    /**
     * A file on an element is also attached to its package, so the package's standard Files list shows every
     * document. Re-linking an already-linked file is skipped.
     */
    public static void mirrorElementFilesToPackages(List<ContentDocumentLink> links) {
        Map<Id, Id> packageByElement = packageIdsByElement(links);
        if (packageByElement.isEmpty()) {
            return;
        }
        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            documentIds.add(link.ContentDocumentId);
        }
        Set<String> existing = new Set<String>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :documentIds AND LinkedEntityId IN :new Set<Id>(packageByElement.values())
            WITH SYSTEM_MODE
        ]) {
            existing.add(link.ContentDocumentId + ':' + link.LinkedEntityId);
        }
        List<ContentDocumentLink> mirrors = new List<ContentDocumentLink>();
        for (ContentDocumentLink link : links) {
            Id packageId = packageByElement.get(link.LinkedEntityId);
            if (packageId != null && existing.add(link.ContentDocumentId + ':' + packageId)) {
                mirrors.add(
                    new ContentDocumentLink(ContentDocumentId = link.ContentDocumentId, LinkedEntityId = packageId, ShareType = 'V', Visibility = 'AllUsers')
                );
            }
        }
        Database.insert(mirrors, AccessLevel.SYSTEM_MODE);
    }

    /** When a file is removed from an element, it is removed from the package unless another element still has it. */
    public static void unmirrorElementFilesFromPackages(List<ContentDocumentLink> links) {
        Map<Id, Id> packageByElement = packageIdsByElement(links);
        if (packageByElement.isEmpty()) {
            return;
        }
        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            documentIds.add(link.ContentDocumentId);
        }
        Set<Id> packageIds = new Set<Id>(packageByElement.values());
        Map<Id, Id> packageOfEveryElement = new Map<Id, Id>();
        for (DNAMS_Package_Element__c element : [SELECT Id, Package__c FROM DNAMS_Package_Element__c WHERE Package__c IN :packageIds WITH SYSTEM_MODE]) {
            packageOfEveryElement.put(element.Id, element.Package__c);
        }
        Set<String> stillOnElements = new Set<String>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :documentIds AND LinkedEntityId IN :packageOfEveryElement.keySet()
            WITH SYSTEM_MODE
        ]) {
            stillOnElements.add(link.ContentDocumentId + ':' + packageOfEveryElement.get(link.LinkedEntityId));
        }
        List<ContentDocumentLink> stale = new List<ContentDocumentLink>();
        for (ContentDocumentLink link : [
            SELECT Id, ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :documentIds AND LinkedEntityId IN :packageIds
            WITH SYSTEM_MODE
        ]) {
            if (!stillOnElements.contains(link.ContentDocumentId + ':' + link.LinkedEntityId)) {
                stale.add(link);
            }
        }
        Database.delete(stale, AccessLevel.SYSTEM_MODE);
    }

    private static Map<Id, Id> packageIdsByElement(List<ContentDocumentLink> links) {
        Set<Id> elementIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            if (isElementId(link.LinkedEntityId)) {
                elementIds.add(link.LinkedEntityId);
            }
        }
        Map<Id, Id> packageByElement = new Map<Id, Id>();
        if (elementIds.isEmpty()) {
            return packageByElement;
        }
        for (DNAMS_Package_Element__c element : [SELECT Id, Package__c FROM DNAMS_Package_Element__c WHERE Id IN :elementIds WITH SYSTEM_MODE]) {
            packageByElement.put(element.Id, element.Package__c);
        }
        return packageByElement;
    }

    /**
     * Before insert of ContentVersion: rejects guest uploads with a bad element/token pair,
     * and new versions of files that sit on elements of packages that are no longer editable.
     */
    public static void validateVersions(List<ContentVersion> versions) {
        Map<Integer, UploadTarget> targets = parseUploadTargets(versions);
        if (!targets.isEmpty()) {
            Map<Id, DNAMS_Package_Element__c> elements = elementsWithPackage(elementIdsOf(targets.values()));
            for (Integer index : targets.keySet()) {
                ContentVersion version = versions[index];
                UploadTarget target = targets.get(index);
                DNAMS_Package_Element__c element = target == null ? null : elements.get(target.elementId);
                if (element == null || !target.token.equals(element.Package__r.Upload_Token__c)) {
                    version.addError(INVALID_UPLOAD_MESSAGE);
                } else if (!EDITABLE_STATUSES.contains(element.Package__r.Status__c)) {
                    version.addError(LOCKED_MESSAGE);
                }
            }
        }
        blockLockedVersions(versions);
    }

    /** After insert of ContentVersion: links validated guest uploads to their element. */
    public static void linkUploadedVersions(List<ContentVersion> versions) {
        Map<Integer, UploadTarget> targets = parseUploadTargets(versions);
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Integer index : targets.keySet()) {
            ContentVersion version = versions[index];
            UploadTarget target = targets.get(index);
            if (target != null && version.ContentDocumentId != null) {
                links.add(
                    new ContentDocumentLink(
                        ContentDocumentId = version.ContentDocumentId,
                        LinkedEntityId = target.elementId,
                        ShareType = 'V',
                        Visibility = 'AllUsers'
                    )
                );
            }
        }
        Database.insert(links, AccessLevel.SYSTEM_MODE);
    }

    // ------------------------------------------------------------------ Rules

    private static void blockLockedVersions(List<ContentVersion> versions) {
        Set<Id> documentIds = new Set<Id>();
        for (ContentVersion version : versions) {
            if (version.ContentDocumentId != null) {
                documentIds.add(version.ContentDocumentId);
            }
        }
        if (documentIds.isEmpty()) {
            return;
        }
        Map<Id, Set<Id>> elementIdsByDocumentId = new Map<Id, Set<Id>>();
        Set<Id> elementIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :documentIds
            WITH SYSTEM_MODE
        ]) {
            if (isElementId(link.LinkedEntityId)) {
                elementIds.add(link.LinkedEntityId);
                if (!elementIdsByDocumentId.containsKey(link.ContentDocumentId)) {
                    elementIdsByDocumentId.put(link.ContentDocumentId, new Set<Id>());
                }
                elementIdsByDocumentId.get(link.ContentDocumentId).add(link.LinkedEntityId);
            }
        }
        if (elementIds.isEmpty()) {
            return;
        }
        Set<Id> lockedElementIds = lockedElementIds(elementIds);
        for (ContentVersion version : versions) {
            Set<Id> linkedElements = elementIdsByDocumentId.get(version.ContentDocumentId);
            if (linkedElements == null) {
                continue;
            }
            for (Id elementId : linkedElements) {
                if (lockedElementIds.contains(elementId)) {
                    version.addError(LOCKED_MESSAGE);
                    break;
                }
            }
        }
    }

    private static void setPackageNames(List<DNAMS_Package__c> packages, Map<Id, DNAMS_Package__c> oldById) {
        List<DNAMS_Package__c> toName = new List<DNAMS_Package__c>();
        Set<Id> accountIds = new Set<Id>();
        for (DNAMS_Package__c pkg : packages) {
            DNAMS_Package__c old = oldById == null ? null : oldById.get(pkg.Id);
            Boolean changed =
                old == null ||
                pkg.Type__c != old.Type__c ||
                pkg.Buying_Dealer__c != old.Buying_Dealer__c ||
                pkg.Selling_Dealer__c != old.Selling_Dealer__c;
            if (changed) {
                toName.add(pkg);
                accountIds.add(pkg.Buying_Dealer__c);
                accountIds.add(pkg.Selling_Dealer__c);
            }
        }
        if (toName.isEmpty()) {
            return;
        }
        accountIds.remove(null);
        Map<Id, Account> accounts = new Map<Id, Account>(
            [SELECT Name, AccountNumber FROM Account WHERE Id IN :accountIds WITH SYSTEM_MODE]
        );
        for (DNAMS_Package__c pkg : toName) {
            pkg.Package_Name__c = buildPackageName(
                dealerCode(accounts.get(pkg.Buying_Dealer__c)),
                pkg.Type__c,
                dealerCode(accounts.get(pkg.Selling_Dealer__c))
            );
        }
    }

    @TestVisible
    private static String buildPackageName(String buyingCode, String packageType, String sellingCode) {
        List<String> parts = new List<String>();
        for (String part : new List<String>{ buyingCode, packageType, sellingCode }) {
            if (String.isNotBlank(part)) {
                parts.add(part);
            }
        }
        return String.join(parts, ' - ').left(255);
    }

    /** Dealer code is the Account Number; temp dealers without one fall back to the account name. */
    private static String dealerCode(Account dealer) {
        if (dealer == null) {
            return null;
        }
        return String.isNotBlank(dealer.AccountNumber) ? dealer.AccountNumber : dealer.Name;
    }

    /** Each package gets its own new elements; only the element types are shared. */
    private static void createElements(List<DNAMS_Package__c> packages) {
        Set<Id> packageIds = new Map<Id, DNAMS_Package__c>(packages).keySet();
        Set<Id> alreadyStarted = new Set<Id>();
        for (AggregateResult row : [
            SELECT Package__c packageId
            FROM DNAMS_Package_Element__c
            WHERE Package__c IN :packageIds
            WITH SYSTEM_MODE
            GROUP BY Package__c
        ]) {
            alreadyStarted.add((Id) row.get('packageId'));
        }

        List<DNAMS_Element_Type__c> elementTypes = [
            SELECT Id, Name, Sort_Order__c, Is_Required__c
            FROM DNAMS_Element_Type__c
            WHERE Is_Active__c = TRUE
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST, Name
        ];

        List<DNAMS_Package_Element__c> elements = new List<DNAMS_Package_Element__c>();
        for (DNAMS_Package__c pkg : packages) {
            if (alreadyStarted.contains(pkg.Id)) {
                continue; // Returned -> Initiated again must not duplicate elements.
            }
            if (elementTypes.isEmpty()) {
                pkg.addError('No active element types are configured.');
                continue;
            }
            for (DNAMS_Element_Type__c elementType : elementTypes) {
                elements.add(
                    new DNAMS_Package_Element__c(
                        Name = elementType.Name,
                        Package__c = pkg.Id,
                        Element_Type__c = elementType.Id,
                        Is_Required__c = elementType.Is_Required__c,
                        Sort_Order__c = elementType.Sort_Order__c
                    )
                );
            }
        }
        Database.insert(elements, AccessLevel.SYSTEM_MODE);
    }

    private static void validateRequiredDocuments(List<DNAMS_Package__c> packages) {
        Map<Id, DNAMS_Package__c> checkById = new Map<Id, DNAMS_Package__c>();
        for (DNAMS_Package__c pkg : packages) {
            if (!pkg.Dealer_Submit_Validation_Override__c) {
                checkById.put(pkg.Id, pkg);
            }
        }
        if (checkById.isEmpty()) {
            return;
        }

        Map<Id, List<DNAMS_Package_Element__c>> requiredByPackage = new Map<Id, List<DNAMS_Package_Element__c>>();
        Set<Id> startedPackages = new Set<Id>();
        Set<Id> requiredElementIds = new Set<Id>();
        for (DNAMS_Package_Element__c element : [
            SELECT Id, Name, Package__c, Is_Required__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c IN :checkById.keySet()
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            startedPackages.add(element.Package__c);
            if (element.Is_Required__c) {
                requiredElementIds.add(element.Id);
                if (!requiredByPackage.containsKey(element.Package__c)) {
                    requiredByPackage.put(element.Package__c, new List<DNAMS_Package_Element__c>());
                }
                requiredByPackage.get(element.Package__c).add(element);
            }
        }

        Set<Id> elementsWithDocuments = new Set<Id>();
        if (!requiredElementIds.isEmpty()) {
            for (ContentDocumentLink link : [
                SELECT LinkedEntityId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :requiredElementIds
                WITH SYSTEM_MODE
            ]) {
                elementsWithDocuments.add(link.LinkedEntityId);
            }
        }

        for (DNAMS_Package__c pkg : checkById.values()) {
            if (!startedPackages.contains(pkg.Id)) {
                pkg.addError('The package has no elements yet.');
                continue;
            }
            List<String> missing = new List<String>();
            for (DNAMS_Package_Element__c element : requiredByPackage.get(pkg.Id) ?? new List<DNAMS_Package_Element__c>()) {
                if (!elementsWithDocuments.contains(element.Id)) {
                    missing.add(element.Name);
                }
            }
            if (!missing.isEmpty()) {
                pkg.addError('Upload at least one document for: ' + String.join(missing, ', ') + '.');
            }
        }
    }

    private static void assignCentralRmrQueue(List<DNAMS_Package__c> packages) {
        List<Group> queues = [
            SELECT Id
            FROM Group
            WHERE Type = 'Queue' AND DeveloperName = :CENTRAL_RMR_QUEUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (queues.isEmpty()) {
            return;
        }
        for (DNAMS_Package__c pkg : packages) {
            pkg.OwnerId = queues[0].Id;
        }
    }

    // ------------------------------------------------------------------ Helpers

    private static String newUploadToken() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(256));
    }

    private static Boolean statusChangedTo(DNAMS_Package__c pkg, Map<Id, DNAMS_Package__c> oldById, String status) {
        if (pkg.Status__c != status) {
            return false;
        }
        DNAMS_Package__c old = oldById == null ? null : oldById.get(pkg.Id);
        return old == null || old.Status__c != status;
    }

    private static Boolean isElementId(Id recordId) {
        return recordId != null && recordId.getSobjectType() == DNAMS_Package_Element__c.SObjectType;
    }

    private static Set<Id> lockedElementIds(Set<Id> elementIds) {
        Set<Id> locked = new Set<Id>();
        for (DNAMS_Package_Element__c element : elementsWithPackage(elementIds).values()) {
            if (element.Package__r != null && !EDITABLE_STATUSES.contains(element.Package__r.Status__c)) {
                locked.add(element.Id);
            }
        }
        return locked;
    }

    private static Map<Id, DNAMS_Package_Element__c> elementsWithPackage(Set<Id> elementIds) {
        return new Map<Id, DNAMS_Package_Element__c>(
            [
                SELECT Id, Package__r.Status__c, Package__r.Upload_Token__c
                FROM DNAMS_Package_Element__c
                WHERE Id IN :elementIds
                WITH SYSTEM_MODE
            ]
        );
    }

    /** Index of each version carrying an upload value; the map value is null when the value is malformed. */
    private static Map<Integer, UploadTarget> parseUploadTargets(List<ContentVersion> versions) {
        Map<Integer, UploadTarget> targets = new Map<Integer, UploadTarget>();
        for (Integer i = 0; i < versions.size(); i++) {
            String value = versions[i].DNAMS_Upload_Token_fileupload__c;
            if (String.isNotBlank(value)) {
                targets.put(i, parseUploadTarget(value));
            }
        }
        return targets;
    }

    private static Set<Id> elementIdsOf(List<UploadTarget> targets) {
        Set<Id> ids = new Set<Id>();
        for (UploadTarget target : targets) {
            if (target != null) {
                ids.add(target.elementId);
            }
        }
        return ids;
    }

    private class UploadTarget {
        Id elementId;
        String token;

        UploadTarget(Id elementId, String token) {
            this.elementId = elementId;
            this.token = token;
        }
    }

    /** Parses "elementId:token"; returns null when malformed or not an element id. */
    private static UploadTarget parseUploadTarget(String value) {
        List<String> parts = value.split(':');
        if (parts.size() != 2 || String.isBlank(parts[1])) {
            return null;
        }
        try {
            Id elementId = Id.valueOf(parts[0]);
            return isElementId(elementId) ? new UploadTarget(elementId, parts[1]) : null;
        } catch (StringException e) {
            return null;
        }
    }
}