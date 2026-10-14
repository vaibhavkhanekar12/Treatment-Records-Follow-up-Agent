/**
 * Inbound-email capture for case-manager review.
 *
 * Captures the email/attachments and performs only safe, deterministic matching
 * when the email explicitly contains a Matter reference and Provider name.
 * No clinical extraction, legal reasoning, or external communication is performed.
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
            result.success = true;
            return result;
        }

        Savepoint captureSavepoint = Database.setSavepoint();
        try {
            String bodyText = String.isNotBlank(email.plainTextBody)
                ? email.plainTextBody
                : '';
            if (String.isBlank(bodyText) && String.isNotBlank(email.htmlBody)) {
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

            String matterReference = extractValue(bodyText, 'matter reference:');
            if (String.isBlank(matterReference)) {
                matterReference = extractValue(bodyText, 'matter:');
            }
            String providerName = extractValue(bodyText, 'provider:');

            Id matchedMatterId = findMatterId(matterReference);
            Id matchedProviderId = findProviderId(providerName);

            List<String> reviewNotes = new List<String>();
            reviewNotes.add('Email and attachments were captured for case-manager review.');
            if (matchedMatterId != null) {
                reviewNotes.add('Matter matched from the explicit Matter reference in the email.');
            } else if (String.isNotBlank(matterReference)) {
                reviewNotes.add('Matter reference was provided but no unique Matter match was found.');
            }
            if (matchedProviderId != null) {
                reviewNotes.add('Provider matched from the explicit Provider name in the email.');
            } else if (String.isNotBlank(providerName)) {
                reviewNotes.add('Provider name was provided but no unique Provider match was found.');
            }

            Automatic_Intake__c intake = new Automatic_Intake__c(
                Email_Message_Id__c = sourceKey,
                Sender_Email__c = safeEmail(email.fromAddress),
                Subject__c = clip(email.subject, 255),
                Received_At__c = System.now(),
                Body_Text__c = bodyText,
                Status__c = 'Needs Review',
                Classification__c = classify(clip(email.subject, 255), bodyText),
                Attachment_Count__c = binaryFiles.size() + textFiles.size(),
                Matched_Matter__c = matchedMatterId,
                Matched_Provider__c = matchedProviderId,
                Review_Reason__c = String.join(reviewNotes, ' ')
            );
            insert intake;

            List<ContentVersion> versions = new List<ContentVersion>();
            for (Messaging.InboundEmail.BinaryAttachment attachment : binaryFiles) {
                if (attachment == null || attachment.body == null) continue;
                String fileName = safeFileName(attachment.fileName);
                versions.add(new ContentVersion(
                    Title = clip(removeExtension(fileName), 255),
                    PathOnClient = fileName,
                    VersionData = attachment.body
                ));
            }
            for (Messaging.InboundEmail.TextAttachment attachment : textFiles) {
                if (attachment == null || attachment.body == null) continue;
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
                        Visibility = 'InternalUsers'
                    ));
                }
                if (!links.isEmpty()) insert links;
            }

            result.success = true;
            return result;
        } catch (Exception ex) {
            Database.rollback(captureSavepoint);
            result.message = 'Intake capture failed: ' + ex.getMessage();
            return result;
        }
    }

    @TestVisible
    private static String extractValue(String body, String label) {
        if (String.isBlank(body) || String.isBlank(label)) return null;
        String normalizedLabel = label.toLowerCase();
        for (String line : body.split('\\n')) {
            if (line == null) continue;
            String trimmed = line.trim();
            String lower = trimmed.toLowerCase();
            if (lower.startsWith(normalizedLabel)) {
                String value = trimmed.substring(label.length()).trim();
                return String.isBlank(value) ? null : clip(value, 255);
            }
        }
        return null;
    }

    private static Id findMatterId(String matterReference) {
        if (String.isBlank(matterReference)) return null;
        List<Matter__c> matches = [
            SELECT Id, Name
            FROM Matter__c
            WHERE Name = :matterReference.trim()
            LIMIT 2
        ];
        return matches.size() == 1 ? matches[0].Id : null;
    }

    private static Id findProviderId(String providerName) {
        if (String.isBlank(providerName)) return null;
        List<Medical_Provider__c> matches = [
            SELECT Id, Name
            FROM Medical_Provider__c
            WHERE Name = :providerName.trim()
            LIMIT 2
        ];
        return matches.size() == 1 ? matches[0].Id : null;
    }

    @TestVisible
    private static String buildSourceKey(Messaging.InboundEmail email) {
        if (String.isNotBlank(email.messageId)) return clip(email.messageId.trim(), 255);
        String material = String.valueOf(email.fromAddress) + '\n' +
            String.valueOf(email.subject) + '\n' +
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
            text.contains('visit summary') || text.contains('discharge summary')) return 'Treatment';
        if (text.contains('provider') || text.contains('clinic') ||
            text.contains('hospital') || text.contains('fax number')) return 'Provider Information';
        return 'Other';
    }

    private static String safeEmail(String value) {
        if (String.isBlank(value) || value.length() > 80 || !value.contains('@')) return null;
        return value;
    }

    private static String safeFileName(String value) {
        String candidate = String.isBlank(value) ? 'InboundAttachment.txt' : value;
        candidate = candidate.replaceAll('[\\\\/:*?"<>|]', '_');
        if (candidate.length() > 180) candidate = candidate.substring(candidate.length() - 180);
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
