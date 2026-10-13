/**
 * Applies structured extraction results to the existing PI data model.
 *
 * An extractor must supply evidence-backed fields and an unambiguous Matter match. This service
 * fails closed: low confidence, missing required data, or an ambiguous match always stays in review.
 * No outbound communications are sent or approved here.
 */
public with sharing class AutomaticIntakeService {
    public static final Decimal MIN_AUTO_CREATE_CONFIDENCE = 0.90;

    public class ExtractedPayload {
        @AuraEnabled public Id intakeId;
        @AuraEnabled public String documentType;
        @AuraEnabled public Decimal confidence;
        @AuraEnabled public Id matterId;
        @AuraEnabled public Boolean matterMatchUnambiguous;
        @AuraEnabled public Id providerId;
        @AuraEnabled public String providerName;
        @AuraEnabled public String providerEmail;
        @AuraEnabled public String providerPhone;
        @AuraEnabled public Date treatmentDate;
        @AuraEnabled public String treatmentStatus;
        @AuraEnabled public String requestType;
        @AuraEnabled public Date requestedDate;
        @AuraEnabled public Date receivedDate;
    }

    public class ApplyResult {
        @AuraEnabled public Boolean applied = false;
        @AuraEnabled public Boolean needsReview = false;
        @AuraEnabled public String message;
        @AuraEnabled public Id createdRecordId;
        @AuraEnabled public Id providerId;
    }

    public static ApplyResult applyValidatedPayload(ExtractedPayload payload) {
        if (payload == null || payload.intakeId == null) {
            throw new AuraHandledException('A valid intake record is required.');
        }
        Automatic_Intake__c intake = [
            SELECT Id, Status__c, Matched_Matter__c, Matched_Provider__c,
                   Classification__c, Review_Reason__c
            FROM Automatic_Intake__c
            WHERE Id = :payload.intakeId
            LIMIT 1
            FOR UPDATE
        ];
        if (intake.Status__c == 'Applied') {
            ApplyResult alreadyApplied = new ApplyResult();
            alreadyApplied.applied = true;
            alreadyApplied.message = 'This intake has already been applied.';
            return alreadyApplied;
        }
        if (intake.Status__c == 'Rejected') {
            throw new AuraHandledException('Rejected intake cannot be applied.');
        }

        String validationProblem = validate(payload);
        if (validationProblem != null) {
            intake.Status__c = 'Needs Review';
            intake.Review_Reason__c = validationProblem;
            update intake;
            ApplyResult review = new ApplyResult();
            review.needsReview = true;
            review.message = validationProblem;
            return review;
        }

        // Verify the target Matter is accessible to the invoking user before creating related data.
        List<Matter__c> matters = [
            SELECT Id
            FROM Matter__c
            WHERE Id = :payload.matterId
            WITH USER_MODE
            LIMIT 1
        ];
        if (matters.isEmpty()) {
            intake.Status__c = 'Needs Review';
            intake.Review_Reason__c = 'The proposed Matter is not accessible or could not be verified.';
            update intake;
            ApplyResult review = new ApplyResult();
            review.needsReview = true;
            review.message = intake.Review_Reason__c;
            return review;
        }

        Id providerId = resolveProvider(payload);
        Id createdId;
        if (payload.documentType == 'Treatment') {
            Treatment_Event__c eventRecord = new Treatment_Event__c(
                Matter__c = payload.matterId,
                Medical_Provider__c = providerId,
                Treatment_Date__c = payload.treatmentDate,
                Status__c = payload.treatmentStatus
            );
            insert eventRecord;
            createdId = eventRecord.Id;
        } else if (payload.documentType == 'Medical Records' ||
                   payload.documentType == 'Medical Bills' ||
                   payload.documentType == 'Records and Bills') {
            String requestType = payload.requestType;
            if (String.isBlank(requestType)) {
                requestType = payload.documentType == 'Medical Records' ? 'Records' :
                    payload.documentType == 'Medical Bills' ? 'Bills' : 'Records and Bills';
            }
            Records_Request__c requestRecord = new Records_Request__c(
                Matter__c = payload.matterId,
                Medical_Provider__c = providerId,
                Request_Type__c = requestType,
                Status__c = 'Received',
                Requested_Date__c = payload.requestedDate,
                Received_Date__c = payload.receivedDate == null ? Date.today() : payload.receivedDate
            );
            insert requestRecord;
            createdId = requestRecord.Id;
        } else {
            // Provider-only documents update/create provider information, but must still have a Matter match.
            if (providerId == null) {
                intake.Status__c = 'Needs Review';
                intake.Review_Reason__c = 'Provider details were not sufficient to safely create a provider record.';
                update intake;
                ApplyResult review = new ApplyResult();
                review.needsReview = true;
                review.message = intake.Review_Reason__c;
                return review;
            }
            createdId = providerId;
        }

        intake.Status__c = 'Applied';
        intake.Matched_Matter__c = payload.matterId;
        intake.Matched_Provider__c = providerId;
        intake.Review_Reason__c = null;
        update intake;

        // Treatment_Event__c already invokes its trigger-based evaluation. Other intake record types
        // also need a refresh; reuse the existing queueable evaluator rather than duplicating rules.
        if (payload.documentType != 'Treatment') {
            System.enqueueJob(new FollowUpTreatmentEventEvalQueueable(new Set<Id>{ payload.matterId }));
        }

        ApplyResult applied = new ApplyResult();
        applied.applied = true;
        applied.message = 'Validated intake was applied to the existing Salesforce data model.';
        applied.createdRecordId = createdId;
        applied.providerId = providerId;
        return applied;
    }

    private static String validate(ExtractedPayload payload) {
        if (payload.confidence == null || payload.confidence < MIN_AUTO_CREATE_CONFIDENCE) {
            return 'Extraction confidence is below the automatic-creation threshold; case-manager review is required.';
        }
        if (payload.matterId == null || payload.matterMatchUnambiguous != true) {
            return 'Matter match is missing or ambiguous; case-manager review is required.';
        }
        if (payload.documentType == 'Treatment') {
            if (payload.treatmentDate == null) return 'Treatment date is missing.';
            if (String.isBlank(payload.treatmentStatus) ||
                !new Set<String>{'Completed','Scheduled','Cancelled','No Show'}.contains(payload.treatmentStatus)) {
                return 'Treatment status is missing or invalid.';
            }
        } else if (new Set<String>{'Medical Records','Medical Bills','Records and Bills'}.contains(payload.documentType)) {
            String typeToUse = payload.requestType;
            if (String.isBlank(typeToUse)) {
                typeToUse = payload.documentType == 'Medical Records' ? 'Records' :
                    payload.documentType == 'Medical Bills' ? 'Bills' : 'Records and Bills';
            }
            if (!new Set<String>{'Records','Bills','Records and Bills'}.contains(typeToUse)) {
                return 'Records/bills type is missing or invalid.';
            }
        } else if (payload.documentType != 'Provider Information') {
            return 'Unsupported document type; case-manager review is required.';
        }
        return null;
    }

    private static Id resolveProvider(ExtractedPayload payload) {
        if (payload.providerId != null) {
            List<Medical_Provider__c> selected = [
                SELECT Id
                FROM Medical_Provider__c
                WHERE Id = :payload.providerId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!selected.isEmpty()) return selected[0].Id;
            throw new AuraHandledException('The proposed provider is not accessible or could not be verified.');
        }

        if (String.isNotBlank(payload.providerEmail)) {
            List<Medical_Provider__c> matches = [
                SELECT Id, Name
                FROM Medical_Provider__c
                WHERE Email__c = :payload.providerEmail
                LIMIT 2
            ];
            if (matches.size() == 1) return matches[0].Id;
            if (matches.size() > 1) {
                throw new AuraHandledException('Provider email matches multiple records; review is required.');
            }
        }
        if (String.isBlank(payload.providerName) || String.isBlank(payload.providerEmail)) {
            // Provider is optional for some existing record models; do not invent one.
            return null;
        }
        Medical_Provider__c provider = new Medical_Provider__c(
            Name = payload.providerName.trim(),
            Email__c = payload.providerEmail.trim(),
            Phone__c = payload.providerPhone
        );
        insert provider;
        return provider.Id;
    }
}