// SCRATCH / DEV ORGS ONLY. Creates synthetic, non-identifying sample data covering every rule.
// Never run in production.
Date today = Date.today();
Medical_Provider__c pt = new Medical_Provider__c(Name = 'Sample Physical Therapy', Email__c = 'records@sample-pt.example', Fax__c = '555-0101');
Medical_Provider__c imaging = new Medical_Provider__c(Name = 'Sample Imaging Center', Fax__c = '555-0102');
insert new List<Medical_Provider__c>{ pt, imaging };

List<Contact> clients = new List<Contact>{
    new Contact(FirstName = 'Alex', LastName = 'Sample', Email = 'alex.sample@example.com', MobilePhone = '555-0111'),
    new Contact(FirstName = 'Blake', LastName = 'Sample', Email = 'blake.sample@example.com'),
    new Contact(FirstName = 'Casey', LastName = 'Sample')
};
insert clients;

List<Matter__c> matters = new List<Matter__c>{
    // treatment gap + missing bills + outstanding records
    new Matter__c(Name = 'SAMPLE-001', Status__c = 'Treating', Practice_Area__c = 'Personal Injury', Client__c = clients[0].Id, Case_Manager__c = UserInfo.getUserId(), Sign_Up_Date__c = today.addDays(-120)),
    // recent treatment, monthly update due
    new Matter__c(Name = 'SAMPLE-002', Status__c = 'Treating', Practice_Area__c = 'Personal Injury', Client__c = clients[1].Id, Case_Manager__c = UserInfo.getUserId(), Sign_Up_Date__c = today.addDays(-45)),
    // potentially stalled, no reachable client channel
    new Matter__c(Name = 'SAMPLE-003', Status__c = 'Open', Practice_Area__c = 'Personal Injury', Client__c = clients[2].Id, Case_Manager__c = UserInfo.getUserId(), Sign_Up_Date__c = today.addDays(-200))
};
insert matters;

insert new List<SObject>{
    new Treatment_Event__c(Matter__c = matters[0].Id, Medical_Provider__c = pt.Id, Treatment_Date__c = today.addDays(-35), Status__c = 'Completed'),
    new Treatment_Event__c(Matter__c = matters[1].Id, Medical_Provider__c = pt.Id, Treatment_Date__c = today.addDays(-4), Status__c = 'Completed'),
    new Treatment_Event__c(Matter__c = matters[1].Id, Medical_Provider__c = pt.Id, Treatment_Date__c = today.addDays(10), Status__c = 'Scheduled'),
    new Treatment_Event__c(Matter__c = matters[2].Id, Medical_Provider__c = imaging.Id, Treatment_Date__c = today.addDays(-90), Status__c = 'Completed'),
    new Records_Request__c(Matter__c = matters[0].Id, Medical_Provider__c = pt.Id, Request_Type__c = 'Records', Status__c = 'Requested', Requested_Date__c = today.addDays(-20)),
    new Records_Request__c(Matter__c = matters[2].Id, Medical_Provider__c = imaging.Id, Request_Type__c = 'Records and Bills', Status__c = 'Requested', Requested_Date__c = today.addDays(-80))
};

FollowUpEvaluationService.Summary summary = FollowUpEvaluationService.evaluate(new Map<Id, Matter__c>(matters).keySet(), 'SAMPLE');
System.debug(JSON.serializePretty(summary));
