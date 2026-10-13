/**
 * Asynchronous intake orchestration. Fails closed to review when no approved extraction adapter is configured.
 */
public without sharing class AutomaticIntakeProcessingQueueable implements Queueable {
    private Id intakeId;

    public AutomaticIntakeProcessingQueueable(Id intakeId) {
        this.intakeId = intakeId;
    }

    public void execute(QueueableContext context) {
        if (intakeId == null) return;
        List<Automatic_Intake__c> found = [
            SELECT Id, Status__c, Email_Message_Id__c, Sender_Email__c, Subject__c,
                   Received_At__c, Body_Text__c, Classification__c, Attachment_Count__c,
                   Matched_Matter__c, Matched_Provider__c
            FROM Automatic_Intake__c
            WHERE Id = :intakeId
            LIMIT 1
        ];
        if (found.isEmpty() || found[0].Status__c == 'Applied' || found[0].Status__c == 'Rejected') {
            return;
        }
        Automatic_Intake__c intake = found[0];
        Automatic_Intake_Extraction_Setting__mdt settings =
            Automatic_Intake_Extraction_Setting__mdt.getInstance('Default');

        if (settings == null || settings.Active__c != true ||
            String.isBlank(settings.Extractor_Class__c)) {
            intake.Status__c = 'Needs Review';
            intake.Review_Reason__c =
                'Email and attachments were captured. No approved document-extraction adapter is configured; verify extracted fields and Matter/provider matching before applying records.';
            update intake;
            return;
        }

        try {
            Type extractorType = Type.forName(settings.Extractor_Class__c);
            if (extractorType == null) {
                throw new AutomaticIntakeException('Configured extraction adapter class was not found.');
            }
            Object instance = extractorType.newInstance();
            if (!(instance instanceof IAutomaticIntakeExtractor)) {
                throw new AutomaticIntakeException('Configured extraction adapter does not implement IAutomaticIntakeExtractor.');
            }
            IAutomaticIntakeExtractor extractor = (IAutomaticIntakeExtractor) instance;
            AutomaticIntakeService.ExtractedPayload payload = extractor.extract(intake);
            if (payload == null) {
                intake.Status__c = 'Needs Review';
                intake.Review_Reason__c = 'Extraction returned no structured candidate; case-manager review is required.';
                update intake;
                return;
            }
            payload.intakeId = intake.Id;
            AutomaticIntakeService.ApplyResult result =
                AutomaticIntakeService.applyValidatedPayload(payload);
            if (result.needsReview && String.isBlank(intake.Review_Reason__c)) {
                intake.Review_Reason__c = result.message;
                update intake;
            }
        } catch (Exception ex) {
            // Avoid persisting exception text because provider responses can contain sensitive data.
            intake.Status__c = 'Needs Review';
            intake.Review_Reason__c = 'Automatic extraction/application failed. Inspect the source and retry after correcting configuration.';
            update intake;
        }
    }

    public class AutomaticIntakeException extends Exception {}
}