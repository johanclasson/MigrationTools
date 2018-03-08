# MigrationTools

## Migrating a GitHub Repository to TFS/VSTS

The `Convert-Issues.ps1`-script copies issues and milestones from a GitHub repository into work items and iterations in a TFS/VSTS team project. It uses the GitHub REST API to get the information it needs, and creates iterations and work items through the TFS/VSTS REST API.

The following data is copied from milestones to iterations:

| Milestone    | Iteration  | Comment                                                |
| ------------ | ---------- | ------------------------------------------------------ |
| Title        | Name       | Not allowed characters are removed                     |
| Descripion   | -          | This field is ignored                                  |
| Due Date     | End Date   |                                                        |
| Created Date | Start Date | Start Date will never be set to a value after End Date |

The following data is copied from issues to work items:

| Issue          | Work Item           | Comment                                    |
| -------------- | ------------------- | ------------------------------------------ |
| Title          | Title               |                                            |
| Body           | Description         | Markdown is converted into HTML            |
| State          | State               |                                            |
| Labels         | Tags                |                                            |
| Milestone name | Iteration Path      |                                            |
| Url            | Hyperlink           | For historical purpose                     |
| User Login     | Created/Changed By  | User do not need to be present in TFS/VSTS |
| Assignee Login | Assigned To         | User do not need to be present in TFS/VSTS |
| Comment Bodies | History Description | Markdown is converted into HTML            |

Example of how to invoke:

```
./Convert-Issues `
  -GitHubIssuesUrl 'https://api.github.com/repos/MyCompany/MyRepo/issues?state=all' `
  -GithubUsername 'myusername' `
  -GitHubPassword 'abc123' `
  -TfsCollectionUrl 'https://myinstancename.visualstudio.com' `
  -TfsProject 'MyProject' `
  -TfsUsername 'myname@mycompany.se' `
  -TfsPersonalAccessToken 'abc123abc123abc123abc123abc123abc123abc123abc123abc1'
```

### Be Weary of Gotchas

* You need to be a member of the TFS "Project Collection Service Accounts" group to be allowed to use the `bypassRules` query parameter.
* I used basic authentication to login on GitHub. If you have an account with activated two factor authentication that method will not work for you.
* Only milestones that have issues relating to them are migrated. Empty milestones are not included.
* The script defaults to create PBIs, but you can set which type of work item to create with the `WorkItemTypeName`-parameter.
