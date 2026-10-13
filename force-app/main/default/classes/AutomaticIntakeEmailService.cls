/**
 * Salesforce Email Service entry point for inbound client/provider email.
 *
 * Captures source content and attachments only. It deliberately does not infer clinical facts
 * or create Matter/Treatment/Provider/Records records from unverified email text.
 * Configure an Email Service address and restrict allowed senders/domains in the target org.
 */
global without sharing class AutomaticIntakeEmailService implements Messaging.InboundEmailHandler {
    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope envelope
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        result.success = false;

        if (email == null) {
            result.message = 'Inbound email payload was empty.';
            return result;
        }

        String sourceKey = buildSourceKey(email);
        List<Automatic_Intake__c> prior = [
            SELECT Id
            FROM Automatic_Intake__c
            WHERE Email_Message_Id__c = :sourceKey
            LIMIT 1
        ];
        if (!prior.isEmpty()) {
            // Email services may receive the same message more than once. Do not duplicate files.
            result.success = true;
            return result;
        }

        Savepoint captureSavepoint = Database.setSavepoint();
        try {
            String bodyText = String.isNotBlank(email.plainTextBody)
                ? email.plainTextBody
                : '';
            if (String.isBlank(bodyText) && String.isNotBlank(email.htmlBody)) {
                // Preserve a bounded raw HTML body for review; no extraction is attempted here.
                bodyText = email.htmlBody;
            }
            if (bodyText.length() > 32000) {
                bodyText = bodyText.substring(0, 32000);
            }

            List<Messaging.InboundEmail.BinaryAttachment> binaryFiles =
                email.binaryAttachments == null
                    ? new List<Messaging.InboundEmail.BinaryAttachment>()
                    : email.binaryAttachments;
            List<Messaging.InboundEmail.TextAttachment> textFiles =
                email.textAttachments == null
                    ? new List<Messaging.InboundEmail.TextAttachment>()
                    : email.textAttachments;

            Automatic_Intake__c intake = new Automatic_Intake__c(
                Email_Message_Id__c = sourceKey,
                Sender_Email__c = safeEmail(email.fromAddress),
                Subject__c = clip(email.subject, 255),
                Received_At__c = System.now(),
                Body_Text__c = bodyText,
                Status__c = 'Needs Review',
                Classification__c = classify(clip(email.subject, 255), bodyText),
                Attachment_Count__c = binaryFiles.size() + textFiles.size(),
                Review_Reason__c = 'Source captured. Structured extraction and Matter/provider matching must be validated before business records can be created.'
            );
            insert intake;

            List<ContentVersion> versions = new List<ContentVersion>();
            for (Messaging.InboundEmail.BinaryAttachment attachment : binaryFiles) {
                if (attachment == null || attachment.body == null) {
                    continue;
                }
                String fileName = safeFileName(attachment.fileName);
                versions.add(new ContentVersion(
                    Title = clip(removeExtension(fileName), 255),
                    PathOnClient = fileName,
                    VersionData = attachment.body
                ));
            }
            for (Messaging.InboundEmail.TextAttachment attachment : textFiles) {
                if (attachment == null || attachment.body == null) {
                    continue;
                }
                String fileName = safeFileName(attachment.fileName);
                versions.add(new ContentVersion(
                    Title = clip(removeExtension(fileName), 255),
                    PathOnClient = fileName,
                    VersionData = Blob.valueOf(attachment.body)
                ));
            }

            if (!versions.isEmpty()) {
                insert versions;
                List<ContentDocumentLink> links = new List<ContentDocumentLink>();
                for (ContentVersion version : [
                    SELECT Id, ContentDocumentId
                    FROM ContentVersion
                    WHERE Id IN :versions
                ]) {
                    links.add(new ContentDocumentLink(
                        ContentDocumentId = version.ContentDocumentId,
                        LinkedEntityId = intake.Id,
                        ShareType = 'V',
                        Visibility = 'SharedUsers'
                    ));
                }
                if (!links.isEmpty()) {
                    insert links;
                }
            }

            System.enqueueJob(new AutomaticIntakeProcessingQueueable(intake.Id));
            result.success = true;
            return result;
        } catch (Exception ex) {
            Database.rollback(captureSavepoint);
            // Do not expose email/attachment contents in the email-service response.
            result.message = 'Intake capture failed: ' + ex.getMessage();
            return result;
        }
    }

    @TestVisible
    private static String buildSourceKey(Messaging.InboundEmail email) {
        if (String.isNotBlank(email.messageId)) {
            return clip(email.messageId.trim(), 255);
        }
        String material = String.valueOf(email.fromAddress) + '\n' +
            String.valueOf(email.subject) + '\n' +
            String.valueOf(email.date) + '\n' +
            String.valueOf(email.plainTextBody);
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(material))
        );
    }

    @TestVisible
    private static String classify(String subject, String body) {
        String text = ((subject == null ? '' : subject) + ' ' +
            (body == null ? '' : body)).toLowerCase();
        Boolean records = text.contains('medical record') ||
            text.contains('medical records') || text.contains('chart notes') ||
            text.contains('records request');
        Boolean bills = text.contains('medical bill') || text.contains('billing statement') ||
            text.contains('itemized bill');
        if (records && bills) return 'Records and Bills';
        if (records) return 'Medical Records';
        if (bills) return 'Medical Bills';
        if (text.contains('appointment') || text.contains('treatment') ||
            text.contains('visit summary') || text.contains('discharge summary')) {
            return 'Treatment';
        }
        if (text.contains('provider') || text.contains('clinic') ||
            text.contains('hospital') || text.contains('fax number')) {
            return 'Provider Information';
        }
        return 'Other';
    }

    private static String safeEmail(String value) {
        if (String.isBlank(value) || value.length() > 80 || !value.contains('@')) {
            return null;
        }
        return value;
    }

    private static String safeFileName(String value) {
        String candidate = String.isBlank(value) ? 'InboundAttachment.txt' : value;
        candidate = candidate.replaceAll('[\\\\/:*?"<>|]', '_');
        if (candidate.length() > 180) {
            candidate = candidate.substring(candidate.length() - 180);
        }
        return candidate;
    }

    private static String removeExtension(String fileName) {
        Integer dot = fileName == null ? -1 : fileName.lastIndexOf('.');
        return dot > 0 ? fileName.substring(0, dot) : fileName;
    }

    private static String clip(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) return value;
        return value.substring(0, maxLength);
    }
}