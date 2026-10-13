@IsTest
private class AutomaticIntakeEmailServiceTest {
    @IsTest
    static void capturesEmailAndAttachmentOnce() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'provider@example.com';
        email.subject = 'Medical records and billing statement';
        email.plainTextBody = 'Please find the medical records and itemized bill attached.';
        email.messageId = '<intake-test-001@example.com>';

        Messaging.InboundEmail.BinaryAttachment attachment =
            new Messaging.InboundEmail.BinaryAttachment();
        attachment.fileName = 'records.pdf';
        attachment.mimeType = 'application/pdf';
        attachment.body = Blob.valueOf('test attachment bytes');
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ attachment };

        Test.startTest();
        Messaging.InboundEmailResult first =
            new AutomaticIntakeEmailService().handleInboundEmail(email, new Messaging.InboundEnvelope());
        Messaging.InboundEmailResult second =
            new AutomaticIntakeEmailService().handleInboundEmail(email, new Messaging.InboundEnvelope());
        Test.stopTest();

        System.assertEquals(true, first.success, first.message);
        System.assertEquals(true, second.success, second.message);
        List<Automatic_Intake__c> rows = [
            SELECT Id, Status__c, Classification__c, Attachment_Count__c, Sender_Email__c
            FROM Automatic_Intake__c
            WHERE Email_Message_Id__c = '<intake-test-001@example.com>'
        ];
        System.assertEquals(1, rows.size(), 'Duplicate message delivery must not create another intake.');
        System.assertEquals('Needs Review', rows[0].Status__c);
        System.assertEquals('Records and Bills', rows[0].Classification__c);
        System.assertEquals(1, rows[0].Attachment_Count__c);
        System.assertEquals('provider@example.com', rows[0].Sender_Email__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :rows[0].Id
        ], 'The source attachment must be linked to the intake record.');
    }

    @IsTest
    static void fallbackSourceKeyIsDeterministic() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'client@example.com';
        email.subject = 'Appointment update';
        email.plainTextBody = 'My treatment appointment is next week.';
        String first = AutomaticIntakeEmailService.buildSourceKey(email);
        String second = AutomaticIntakeEmailService.buildSourceKey(email);
        System.assertEquals(first, second);
        System.assertEquals(64, first.length());
    }
}