import XCTest
import Foundation

// `StagingDestructivePatterns` and `StagingHazards`: what the app says about a command's text, with no views.
//
//   * The fixed destructive-pattern list (PRD SR6): a table of positive and negative cases for every pattern.
//     A match only labels the row (and, in a production-treated pane, asks first). Every label ends with
//     "No label does not mean safe."; no code path produces a safe, green or check-mark label.
//   * History expansion: the same rule the daemon applies (the cases here are the ones in
//     `tests/fixtures/terminal_staging/hazards.json`).
//   * The look-alike non-ASCII label: code points and names, at most three, then "and N more".

final class StagingHazardsTests: XCTestCase {

    // MARK: Destructive patterns

    func testEveryPatternMatchesItsPositiveCases() {
        let positives: [(command: String, names: [String])] = [
            ("rm -rf /tmp/x", ["rm -rf"]), ("rm -fr /tmp/x", ["rm -rf"]), ("rm -Rf /tmp/x", ["rm -rf"]),
            ("rm -r -f x", ["rm -rf"]), ("rm -f -r x", ["rm -rf"]),
            ("rm --recursive --force x", ["rm -rf", "--force"]), ("rm -r --force x", ["rm -rf", "--force"]), ("sudo rm -rf x && ls", ["rm -rf"]),
            ("ls; rm -rf x", ["rm -rf"]),
            ("DROP TABLE users", ["DROP"]), ("drop table users", ["DROP"]), ("psql -c 'drop database x'", ["DROP"]),
            ("TRUNCATE TABLE users", ["TRUNCATE"]), ("truncate users", ["TRUNCATE"]),
            ("DELETE FROM users", ["DELETE FROM without WHERE"]), ("delete from users;", ["DELETE FROM without WHERE"]),
            ("php artisan migrate:fresh", ["migrate:fresh"]), ("php artisan db:wipe", ["db:wipe"]),
            ("php artisan queue:flush", ["queue:flush"]), ("php artisan cache:clear", ["cache:clear"]),
            ("PHP ARTISAN MIGRATE:FRESH", ["migrate:fresh"]),
            ("git push --force", ["--force"]), ("git push --force-with-lease", ["--force"]), ("composer install --force", ["--force"]),
            ("kill -9 123", ["kill -9"]), ("pkill -9 x", ["kill -9"]), ("killall -KILL x", ["kill -9"]),
            ("kill -SIGKILL 1", ["kill -9"]), ("kill -s 9 1", ["kill -9"]), ("kill -s KILL 1", ["kill -9"]),
            ("kill -s SIGKILL 1", ["kill -9"]),
            ("php artisan queue:flush && php artisan cache:clear", ["queue:flush", "cache:clear"]),
            ("rm -rf x; DROP TABLE y", ["rm -rf", "DROP"]),
        ]
        for (command, names) in positives {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), names, command)
        }
    }

    func testTheNegativeCasesMatchNothing() {
        let negatives = [
            "ls -la", "git push", "git status", "rm x", "rm -r x", "rm -f x", "rm -v x", "echo -rf",
            "rm x | grep -rf y", "rm x; echo -rf", "DELETE FROM users WHERE id = 1", "delete from t where x=1",
            "echo drops", "echo truncated", "git push --forceful", "kill 123", "kill -15 1", "kill -s 15 1",
            "pkill -f x", "cat migrate", "php artisan cache:forget x",
        ]
        for command in negatives {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    func testTheListIsExactlyTheFixedOneInOrder() {
        XCTAssertEqual(StagingDestructivePatterns.names, ["rm -rf", "DROP", "TRUNCATE", "DELETE FROM without WHERE", "migrate:fresh",
                                                          "db:wipe", "queue:flush", "cache:clear", "--force", "kill -9",
                                                          "migrate:refresh", "migrate:reset", "migrate:rollback", "kubectl delete",
                                                          "kubectl drain", "helm uninstall", "terraform destroy", "aws delete/terminate",
                                                          "aws s3 rm/rb", "dd of=", "mkfs", "shred", "> file", "find -delete",
                                                          "xargs/piped rm"])
        XCTAssertEqual(StagingDestructivePatterns.names.count, 25)
        XCTAssertEqual(Set(StagingDestructivePatterns.names).count, 25, "the names are unique")
    }

    func testEveryPatternLabelSaysNoLabelDoesNotMeanSafeAndNothingSaysSafe() {
        XCTAssertEqual(StagingHazards.destructiveLabel(["queue:flush"], production: true),
                       "\u{26A0} Matches a destructive pattern (queue:flush). Insert asks first. No label does not mean safe.")
        XCTAssertEqual(StagingHazards.destructiveLabel(["queue:flush"], production: false),
                       "\u{26A0} Matches a destructive pattern (queue:flush). No label does not mean safe.")
        XCTAssertEqual(StagingHazards.destructiveLabel(["rm -rf", "DROP"], production: true),
                       "\u{26A0} Matches a destructive pattern (rm -rf, DROP). Insert asks first. No label does not mean safe.")
        XCTAssertNil(StagingHazards.destructiveLabel([], production: true), "no match, no label")
        for production in [true, false] {
            for name in StagingDestructivePatterns.names {
                let label = StagingHazards.destructiveLabel([name], production: production) ?? ""
                XCTAssertTrue(label.contains("No label does not mean safe."), label)
                XCTAssertFalse(label.replacingOccurrences(of: "No label does not mean safe.", with: "").lowercased().contains("safe"), label)
                XCTAssertFalse(label.contains("\u{2713}") || label.contains("\u{2705}"), label)
            }
        }
    }

    // MARK: Wrapped, split and abbreviated forms (M2, S4, P4)

    func testRmRfIsSeenThroughWrapping() {
        let wrapped = [
            "bash -c 'rm -rf /srv/app/cache'", "sh -c \"rm -rf x\"", "echo $(rm -rf x)", "echo `rm -rf x`", "(rm -rf x)",
            "{ rm -rf x; }", "\\rm -rf x", "\"rm\" -rf x", "r''m -rf x", "command rm -rf x", "/bin/rm -rf x", "env rm -rf x",
            "rm -r --forc x", "rm --recurs -f x", "rm -rf x", "ls & rm -rf x", "xargs rm -rf",
        ]
        for command in wrapped {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains("rm -rf"), command)
        }
        XCTAssertFalse(StagingDestructivePatterns.matches("bash -c 'rm x'").contains("rm -rf"))
        XCTAssertFalse(StagingDestructivePatterns.matches("echo \"rm\" -r x").contains("rm -rf"))
    }

    func testLaravelAbbreviationsAndSplitWordsMatch() {
        let cases: [(String, String)] = [
            ("php artisan ca:cl", "cache:clear"), ("php artisan q:fl", "queue:flush"), ("php artisan mi:fr", "migrate:fresh"),
            ("php artisan db:w", "db:wipe"), ("php artisan migrate:fre''sh", "migrate:fresh"),
            ("php artisan cache:cle\\ar", "cache:clear"), ("php artisan \"queue\":flush", "queue:flush"),
        ]
        for (command, name) in cases {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains(name), command)
        }
        XCTAssertEqual(StagingDestructivePatterns.matches("php artisan cache:forget x"), [])
        XCTAssertEqual(StagingDestructivePatterns.matches("php artisan route:list"), [])
    }

    func testSqlCommentsAndShortKillAndForceForms() {
        XCTAssertTrue(StagingDestructivePatterns.matches("mysql -e 'DROP/**/TABLE users'").contains("DROP"))
        XCTAssertTrue(StagingDestructivePatterns.matches("DELETE/**/FROM users").contains("DELETE FROM without WHERE"))
        XCTAssertTrue(StagingDestructivePatterns.matches("kill -n 9 123").contains("kill -9"))
        XCTAssertTrue(StagingDestructivePatterns.matches("git push --forc").contains("--force"))
        XCTAssertEqual(StagingDestructivePatterns.matches("git log --format=x"), [])
    }

    func testEachDeleteStatementIsCheckedOnItsOwn() {
        for command in ["DELETE FROM a WHERE id=1; DELETE FROM b", "DELETE FROM a; SELECT * FROM b WHERE x = 1",
                        "delete from a where id=1; delete from b; select 1"] {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains("DELETE FROM without WHERE"), command)
        }
        XCTAssertEqual(StagingDestructivePatterns.matches("DELETE FROM a WHERE id=1; DELETE FROM b WHERE id=2"), [])
    }

    // MARK: The fifteen families added after the first ten (kubectl, helm, terraform, aws, dd, mkfs, shred, `> file`, find, xargs, ...)
    //
    // Each family: wrapped, quoted, sudo'd, piped and absolute-path variants are still seen, and the read-only
    // look-alikes are not. The list is conservative: an ambiguous command MATCHES (the user is asked to confirm).
    // The daemon's `destructive.rs` is held to the same cases (`src/terminal/staging/tests/destructive.rs`).

    /// Every command carries `name` (and possibly other names).
    private func assertAll(_ name: String, _ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands {
            let found = StagingDestructivePatterns.matches(command)
            XCTAssertTrue(found.contains(name), "\(command) should be labelled \(name), got \(found)", file: file, line: line)
        }
    }

    /// No command matches anything.
    private func assertNone(_ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command, file: file, line: line)
        }
    }

    /// No command carries `name` (other names are not this family's business).
    private func assertNotLabelled(_ name: String, _ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands {
            let found = StagingDestructivePatterns.matches(command)
            XCTAssertFalse(found.contains(name), "\(command) must not be labelled \(name), got \(found)", file: file, line: line)
        }
    }

    func testNewMigrateRefreshResetRollbackFamilyIsSeenThroughWrapping() {
        // Like migrate:fresh: the literal name, any case, and the Laravel abbreviation.
        assertAll("migrate:refresh", [#"php artisan migrate:refresh --seed"#, #"PHP ARTISAN MIGRATE:REFRESH"#, #"php artisan mi:ref"#])
        assertAll("migrate:reset", [#"php artisan migrate:reset"#, #"PHP ARTISAN MIGRATE:RESET"#, #"php artisan mi:rese"#])
        assertAll("migrate:rollback", [#"php artisan migrate:rollback --step=1"#, #"PHP ARTISAN MIGRATE:ROLLBACK"#,
                                       #"php artisan migrate:rol"#, #"php artisan mi:ro"#])
        // migrate resets are seen through wrapping quoting and sudo
        assertAll(#"migrate:refresh"#, [
            #"bash -c 'php artisan migrate:refresh'"#,
            #"php artisan migrate:refre''sh"#,
            #"echo $(php artisan migrate:refresh)"#,
            #"sudo -u www-data php artisan migrate:refresh"#,
        ])
        assertAll(#"migrate:rollback"#, [
            #"php artisan "migrate":rollback"#,
            #"php artisan down && php artisan migrate:rollback; php artisan up"#,
            #"sudo -u www-data php artisan migrate:rollback --force"#,
        ])
        assertAll(#"migrate:reset"#, [
            #"php artisan migrate:res\et"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"sudo -u www-data php artisan migrate:rollback --force"#), ["--force", "migrate:rollback"])
        // migrate abbreviations that fit several commands label all of them
        XCTAssertEqual(StagingDestructivePatterns.matches(#"php artisan mi:re"#), ["migrate:refresh", "migrate:reset"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"php artisan mi:r"#), ["migrate:refresh", "migrate:reset", "migrate:rollback"])
        // migrate look alikes are not resets
        assertNone([
            #"php artisan migrate:status"#,
            #"php artisan migrate"#,
            #"php artisan migrate --pretend"#,
            #"php artisan migrate:install"#,
            #"php artisan make:request StoreUser"#,
            #"php artisan make:migration add_x_to_users"#,
            #"php artisan route:list"#,
        ])
    }

    func testNewKubectlFamilyIsSeenThroughWrapping() {
        // kubectl delete is caught wherever the program sits
        assertAll(#"kubectl delete"#, [
            #"kubectl delete pod web-1"#,
            #"kubectl delete -f deploy.yaml"#,
            #"kubectl -n prod delete pod web-1"#,
            #"kubectl --namespace=prod delete deployment web"#,
            #"KUBECTL delete ns prod"#,
            #"/usr/local/bin/kubectl delete pod web-1"#,
            #"sudo kubectl delete pod web-1"#,
            #"env KUBECONFIG=/x kubectl delete pod web-1"#,
            #"KUBECONFIG=/x kubectl delete pod web-1"#,
            #"command kubectl delete pod web-1"#,
            #"time kubectl delete pod web-1"#,
            #"nohup kubectl delete pod web-1"#,
            #"exec kubectl delete pod web-1"#,
            #"kubectl get pods && kubectl delete pod web-1"#,
            #"echo go; kubectl delete pod web-1"#,
            #"false || kubectl delete pod web-1"#,
            #"echo web-1 | kubectl delete pod web-1"#,
            #"k''ubectl delete pod web-1"#,
            #""kubectl" delete pod web-1"#,
            #"\kubectl delete pod web-1"#,
            #"kubectl del\ete pod web-1"#,
            #"kubectl${IFS}delete${IFS}pod${IFS}web-1"#,
            #"bash -c 'kubectl delete pod web-1'"#,
            #"echo $(kubectl delete pod web-1)"#,
            #"echo `kubectl delete pod web-1`"#,
            #"(kubectl delete pod web-1)"#,
            #"{ kubectl delete pod web-1; }"#,
        ])
        // kubectl drain is caught wherever the program sits
        assertAll(#"kubectl drain"#, [
            #"kubectl drain node-1 --ignore-daemonsets"#,
            #"kubectl --context prod drain node-1"#,
            #"sudo kubectl drain node-1"#,
            #"/usr/bin/kubectl drain node-1"#,
            #"bash -c "kubectl drain node-1""#,
            #"kubectl dr''ain node-1"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"kubectl drain node-1; kubectl delete node node-1"#), ["kubectl delete", "kubectl drain"])
        // kubectl read only look alikes match nothing
        assertNone([
            #"kubectl get pods"#,
            #"kubectl describe pod web-1"#,
            #"kubectl logs web-1"#,
            #"kubectl apply -f x.yaml"#,
            #"kubectl get pod delete-me"#,
            #"kubectl get node drain-me"#,
            #"kubectl get pods; echo delete"#,
        ])
    }

    func testNewHelmFamilyIsSeenThroughWrapping() {
        // helm uninstall and its aliases are caught
        assertAll(#"helm uninstall"#, [
            #"helm uninstall web"#,
            #"helm delete web"#,
            #"helm del web"#,
            #"helm un web"#,
            #"helm -n prod uninstall web"#,
            #"sudo helm uninstall web"#,
            #"/usr/local/bin/helm uninstall web"#,
            #"HELM uninstall web"#,
            #"bash -c 'helm uninstall web'"#,
            #"helm list && helm uninstall web"#,
            #"he''lm uninstall web"#,
            #"helm${IFS}uninstall${IFS}web"#,
            #"echo $(helm uninstall web)"#,
        ])
        // helm read only look alikes match nothing
        assertNone([
            #"helm list"#,
            #"helm install web ./chart"#,
            #"helm upgrade web ./chart"#,
            #"helm status web"#,
            #"helm list --uninstalling"#,
            #"helm list; echo uninstall"#,
        ])
    }

    func testNewTerraformFamilyIsSeenThroughWrapping() {
        // terraform destroy and the ambiguous destroying flags are caught
        assertAll(#"terraform destroy"#, [
            #"terraform destroy"#,
            #"terraform destroy -auto-approve"#,
            #"tofu destroy"#,
            #"terragrunt destroy"#,
            #"terragrunt run-all destroy"#,
            #"terraform apply -destroy"#,
            #"terraform apply --destroy"#,
            #"terraform plan -destroy"#,
            #"terraform apply -replace=aws_instance.web"#,
            #"terraform apply -replace aws_instance.web"#,
            #"tofu apply -replace=aws_instance.web"#,
            #"terraform -chdir=infra destroy"#,
            #"terraform -chdir=infra apply -destroy"#,
            #"sudo terraform destroy"#,
            #"/usr/local/bin/terraform destroy"#,
            #"TF_LOG=debug terraform destroy"#,
            #"env TF_LOG=debug terraform destroy"#,
            #"TERRAFORM destroy"#,
            #"terraform apply -auto-approve && terraform destroy"#,
            #"bash -c 'terraform destroy'"#,
            #"terra''form destroy"#,
            #"terraform "destroy""#,
            #"\terraform destroy"#,
            #"terraform${IFS}destroy"#,
        ])
        // terraform read only and plain apply look alikes match nothing
        assertNone([
            #"terraform apply"#,
            #"terraform plan"#,
            #"terraform init"#,
            #"terraform apply -auto-approve"#,
            #"tofu validate"#,
            #"terraform fmt"#,
            #"terraform state list"#,
            #"terraform plan -out=tfplan"#,
            #"terraform plan; echo destroy"#,
        ])
    }

    func testNewAwsFamilyIsSeenThroughWrapping() {
        assertNotLabelled("aws s3 rm/rb", [#"aws s3 cp a.txt s3://b/a.txt"#, #"aws s3 cp s3://b/k ./out --recursive"#,
                                           #"aws s3 sync ./out s3://b"#, #"aws s3 sync ./out s3://b --dryrun"#,
                                           #"aws s3 mb s3://x"#, #"aws s3 ls s3://rm"#, #"aws s3 ls"#])
        // aws delete terminate remove deregister and purge verbs are caught
        assertAll(#"aws delete/terminate"#, [
            #"aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws s3api delete-object --bucket b --key k"#,
            #"aws s3api delete-bucket --bucket b"#,
            #"aws iam remove-user-from-group --user-name u --group-name g"#,
            #"aws ecs deregister-task-definition --task-definition web:1"#,
            #"aws sqs purge-queue --queue-url q"#,
            #"aws rds delete-db-instance --db-instance-identifier x --skip-final-snapshot"#,
            #"aws --profile prod ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws --region us-east-1 --profile prod ec2 terminate-instances --instance-ids i-0abc"#,
            #"AWS EC2 TERMINATE-INSTANCES --instance-ids i-0abc"#,
            #"sudo aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"/usr/local/bin/aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"AWS_PROFILE=prod aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"env AWS_PROFILE=prod aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"time aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws ec2 describe-instances && aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"a''ws ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws ec2 "terminate-instances" --instance-ids i-0abc"#,
            #"\aws ec2 delete-volume --volume-id vol-0abc"#,
            #"aws ec2 termi\nate-instances --instance-ids i-0abc"#,
            #"bash -c 'aws ec2 terminate-instances --instance-ids i-0abc'"#,
            #"echo $(aws sqs purge-queue --queue-url q)"#,
            #"(aws iam delete-user --user-name u)"#,
            #"aws${IFS}ec2${IFS}terminate-instances${IFS}--instance-ids${IFS}i-0abc"#,
        ])
        // aws read only look alikes match nothing
        assertNone([
            #"aws ec2 describe-instances"#,
            #"aws s3 ls"#,
            #"aws s3api get-object --bucket b --key k out.bin"#,
            #"aws iam list-users"#,
            #"aws sts get-caller-identity"#,
            #"aws s3 ls s3://delete-me"#,
            #"aws logs filter-log-events --log-group-name g"#,
            #"aws ec2 describe-instances --filters Name=tag:x,Values=delete-me"#,
            #"aws ec2 describe-instances; echo terminate-instances"#,
        ])
        // aws s3 rm rb and sync with delete are caught
        assertAll(#"aws s3 rm/rb"#, [
            #"aws s3 rm s3://b/k"#,
            #"aws s3 rm s3://b/k --recursive"#,
            #"aws s3 rb s3://b --force"#,
            #"aws s3 rb s3://b"#,
            #"aws --profile prod s3 rm s3://b/k"#,
            #"aws s3 sync ./out s3://b --delete"#,
            #"aws s3 sync s3://a s3://b --delete --exact-timestamps"#,
            #"sudo aws s3 rm s3://b/k"#,
            #"/usr/local/bin/aws s3 rm s3://b/k"#,
            #"AWS_PROFILE=prod aws s3 rb s3://b"#,
            #"bash -c 'aws s3 rm s3://b/k'"#,
            #""aws" s3 "rm" s3://b/k"#,
            #"aws s3 r''m s3://b/k"#,
            #"aws${IFS}s3${IFS}rm${IFS}s3://b/k"#,
            #"aws s3 ls && aws s3 rm s3://b/k"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"aws s3 rb s3://b --force"#), ["--force", "aws s3 rm/rb"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"aws s3 rm s3://b/k --recursive --force"#), ["rm -rf", "--force", "aws s3 rm/rb"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"aws s3 rm s3://b/k && aws ec2 terminate-instances --instance-ids i-0abc"#), ["aws delete/terminate", "aws s3 rm/rb"])
    }

    func testNewDdMkfsShredAndTruncateFamiliesAreSeenThroughWrapping() {
        // dd with an output file is caught and a read only dd is not
        assertAll(#"dd of="#, [
            #"dd if=/dev/zero of=/dev/sda bs=1M"#,
            #"dd of=/dev/sdb if=disk.img"#,
            #"DD IF=disk.img OF=/dev/sdb"#,
            #"sudo dd if=disk.img of=/dev/sdb"#,
            #"/bin/dd if=disk.img of=/dev/sdb"#,
            #"env LC_ALL=C dd if=disk.img of=/dev/sdb"#,
            #"time dd if=disk.img of=/dev/sdb"#,
            #"nohup dd if=disk.img of=/dev/sdb"#,
            #"cat disk.img | dd of=/dev/sdb"#,
            #"sync && dd if=disk.img of=/dev/sdb"#,
            #"bash -c 'dd if=/dev/zero of=/dev/sda'"#,
            #"echo $(dd if=a of=b)"#,
            #"d''d if=disk.img of=/dev/sdb"#,
            #"dd if=disk.img o''f=/dev/sdb"#,
            #"\dd if=disk.img of=/dev/sdb"#,
            #"dd${IFS}if=disk.img${IFS}of=/dev/sdb"#,
        ])
        assertNone([
            #"dd if=/dev/zero bs=1M count=1"#,
            #"echo odd of=x"#,
            #"ls of=x"#,
            #"dd if=disk.img bs=1 count=1; echo of=x"#,
        ])
        // mkfs and its variants are caught and look alikes are not
        assertAll(#"mkfs"#, [
            #"mkfs /dev/sdb1"#,
            #"mkfs.ext4 /dev/sdb1"#,
            #"/sbin/mkfs -t xfs /dev/sdb1"#,
            #"sudo mkfs.xfs /dev/sdb1"#,
            #"MKFS.EXT4 /dev/sdb1"#,
            #"mkfs.vfat -F 32 /dev/sdb1"#,
            #"X=1 mkfs.ext4 /dev/sdb1"#,
            #"echo go; mkfs.ext4 /dev/sdb1"#,
            #"bash -c 'mkfs.ext4 /dev/sdb1'"#,
            #"mk''fs.ext4 /dev/sdb1"#,
            #"/usr/sbin/mkfs.btrfs -f /dev/sdb1"#,
            #"mkfsx /dev/sdb1"#,
            #"mkfs.ext4${IFS}/dev/sdb1"#,
        ])
        assertNone([
            #"mkdir -p /tmp/x"#,
            #"mk"#,
            #"mktemp -d"#,
            #"echo mkf"#,
        ])
        // shred is caught and look alikes are not
        assertAll(#"shred"#, [
            #"shred -u secret.txt"#,
            #"shred -vzn 3 /dev/sdb"#,
            #"SHRED -u secret.txt"#,
            #"sudo shred -u secret.txt"#,
            #"/usr/bin/shred -u secret.txt"#,
            #"ls | xargs shred -u"#,
            #"bash -c 'shred -u secret.txt'"#,
            #"sh''red -u secret.txt"#,
            #"\shred secret.txt"#,
            #"echo go; shred secret.txt"#,
        ])
        assertNone([
            #"shredder --help"#,
            #"echo shreds"#,
            #"ls shred-notes.txt"#,
        ])
        // truncate the command is the truncate pattern
        XCTAssertEqual(StagingDestructivePatterns.matches(#"truncate -s 0 f"#), ["TRUNCATE"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"sudo truncate -s0 /var/log/app.log"#), ["TRUNCATE"])
    }

    func testNewTruncatingRedirectFamilyIsSeenThroughWrapping() {
        // a truncating redirection is caught in all its spellings
        assertAll(#"> file"#, [
            #": > file"#,
            #":> file"#,
            #"echo hi > out.txt"#,
            #"cat a >b"#,
            #"ls 2>err.log"#,
            #"cmd >| f"#,
            #"cmd >! f"#,
            #"echo x >& log"#,
            #"a &>log"#,
            #"> /var/log/app.log"#,
            #"echo x >$out"#,
            #"ls > /dev/nullx"#,
            #"cmd > /dev/null > out.txt"#,
            #"echo a >(cat)"#,
            #"echo a >"#,
            #"sudo sh -c 'echo x > /etc/conf'"#,
            #"bash -c "cat a > b""#,
            #"echo $(echo x > f)"#,
            #"ls && echo x > f"#,
            #"echo "a > b""#,
        ])
        // appends dups closes and redirections to the bit buckets are not truncations
        assertNone([
            #"echo a >> log"#,
            #"cmd 2>&1"#,
            #"cmd >&2"#,
            #"cmd 1>&2"#,
            #"cmd >&-"#,
            #"ls > /dev/null"#,
            #"ls 2>/dev/null"#,
            #"ls &>/dev/null"#,
            #"ls > /dev/stderr"#,
            #"ls 2>/dev/stdout"#,
            #"ls > /DEV/NULL"#,
            #"ls >& /dev/null"#,
            #"ls &>> log"#,
            #"ls 2>> err.log"#,
            #"cmd 2>&1 | grep x"#,
            #"echo > /dev/null; ls"#,
            #"ls > /dev/null 2>&1"#,
            #"ls 2>&1 >/dev/null"#,
            #"exec 3<>/tmp/sock"#,
            #"echo hello"#,
        ])
        // a redirection is listed after the older names
        XCTAssertEqual(StagingDestructivePatterns.matches(#"echo x > a; kill -9 1"#), ["kill -9", "> file"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"rm -rf x > log"#), ["rm -rf", "> file"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"rm -rf /tmp/x 2>/dev/null"#), ["rm -rf"])
    }

    func testNewFindXargsAndPipedRmFamilyIsSeenThroughWrapping() {
        // find with delete or an exec of rm is caught
        assertAll(#"find -delete"#, [
            #"find . -name x -delete"#,
            #"find . -exec rm {} \;"#,
            #"find . -type f -execdir rm -- {} +"#,
            #"find /tmp -exec sh -c 'rm {}' \;"#,
            #"find . -ok rm {} \;"#,
            #"find . -okdir rm {} \;"#,
            #"find . -exec /bin/rm {} \;"#,
            #"find . -exec RM {} \;"#,
            #"find . -name '*.log' -mtime +7 -delete"#,
            #"/usr/bin/find . -delete"#,
            #"sudo find . -DELETE"#,
            #"FIND . -delete"#,
            #"bash -c 'find . -name x -delete'"#,
            #"echo $(find . -delete)"#,
            #"f''ind . -delete"#,
            #"\find . -delete"#,
            #"ls && find . -delete"#,
            #"find . -delete | cat"#,
            #"find${IFS}.${IFS}-delete"#,
            #"find . -name x -exec grep rm {} \;"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"find . -exec rm -rf {} \;"#), ["rm -rf", "find -delete"])
        // find without delete or rm is not caught
        assertNone([
            #"find . -name x"#,
            #"find . -exec ls {} \;"#,
            #"find . -name delete"#,
            #"find . -print"#,
            #"find . -type f -print0 | sort -z"#,
            #"find . -name '*.log' -exec grep -l error {} +"#,
            #"echo -delete"#,
        ])
        // xargs rm and rm after a pipe are caught
        assertAll(#"xargs/piped rm"#, [
            #"xargs rm"#,
            #"xargs -0 rm -f"#,
            #"xargs -I{} rm {}"#,
            #"xargs 'rm'"#,
            #"ls | xargs rm"#,
            #"ls | sudo rm x"#,
            #"find . | while read f; do rm "$f"; done"#,
            #"echo x | sh -c 'rm y'"#,
            #"cat list | xargs -n1 rm"#,
            #"ls | /bin/rm x"#,
            #"ls | RM x"#,
            #"ls|xargs rm"#,
            #"echo x | env rm y"#,
            #"ls | \rm x"#,
            #"ls | x''args rm"#,
            #"ls | xargs${IFS}rm"#,
            #"bash -c 'ls | xargs rm'"#,
            #"(ls | xargs rm)"#,
            #"echo $(ls | xargs rm)"#,
            #"ls && ls | xargs rm"#,
            #"ls | xargs -P4 -I {} rm {}"#,
            #"ls | rm"#,
            #"find . -name x | xargs rm"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"xargs rm -rf"#), ["rm -rf", "xargs/piped rm"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"ls | xargs rm -rf"#), ["rm -rf", "xargs/piped rm"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"ls | xargs rm -f"#), ["xargs/piped rm"])
        // rm before the pipe or after or or is not piped rm
        assertNone([
            #"rm x | grep y"#,
            #"ls || rm x"#,
            #"rm x"#,
            #"ls | grep rm-me"#,
            #"xargs echo"#,
            #"ls | xargs ls"#,
            #"rm x || ls | cat"#,
            #"echo x | tee y"#,
        ])
    }

    func testNewForceKillFamilyIsSeenThroughWrapping() {
        // every spelling of a force kill is caught
        assertAll(#"kill -9"#, [
            #"kill -s9 1"#,
            #"kill -s KILL 1"#,
            #"kill -SIGKILL 1"#,
            #"kill -KILL 1"#,
            #"kill -n9 1"#,
            #"kill -n 9 1"#,
            #"kill -sKILL 1"#,
            #"kill -ssigkill 1"#,
            #"kill --signal=KILL 1"#,
            #"kill --signal=sigkill 1"#,
            #"kill --signal=9 1"#,
            #"kill --signal 9 1"#,
            #"kill --signal KILL 1"#,
            #"kill 1 -9"#,
            #"pkill -9 x"#,
            #"pkill -f x -9"#,
            #"pkill -f x -KILL"#,
            #"killall -9 x"#,
            #"killall -s KILL x"#,
            #"/bin/kill -9 1"#,
            #"sudo kill -9 1"#,
            #"env kill -9 1"#,
            #"nohup kill -9 1"#,
            #"time kill -9 1"#,
            #"exec kill -9 1"#,
            #"command kill -9 1"#,
            #"KILL -9 1"#,
            #"bash -c 'kill -9 1'"#,
            #"echo $(kill -9 1)"#,
            #"ls && kill -9 1"#,
            #"ls; kill -9 1"#,
            #"pgrep x | xargs kill -9"#,
            #"k''ill -9 1"#,
            #"\kill -9 1"#,
            #"kill${IFS}-9${IFS}1"#,
        ])
        // gentle signals and listing signals are not force kills
        assertNone([
            #"kill 123"#,
            #"kill -15 1"#,
            #"kill -s 15 1"#,
            #"kill -s TERM 1"#,
            #"kill -HUP 1"#,
            #"kill -n 15 1"#,
            #"kill --signal=15 1"#,
            #"pkill -f x"#,
            #"pkill -TERM x"#,
            #"kill -l"#,
            #"killall x"#,
            #"kill 1; echo -9"#,
        ])
    }

    func testSeveralNewFamiliesInOneCommandAreListedInListOrder() {
        // several families in one command are all listed in list order
        XCTAssertEqual(StagingDestructivePatterns.matches(#"kubectl delete pod web-1 && terraform destroy"#), ["kubectl delete", "terraform destroy"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"dd if=a of=b; mkfs.ext4 /dev/sdb; shred x"#), ["dd of=", "mkfs", "shred"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"ls | xargs rm -rf; find . -delete"#), ["rm -rf", "find -delete", "xargs/piped rm"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"helm uninstall web; kubectl delete ns web"#), ["kubectl delete", "helm uninstall"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"kubectl delete pod x --force; php artisan migrate:rollback"#), ["--force", "migrate:rollback", "kubectl delete"])
        // every label comes in list order, once
        let found = StagingDestructivePatterns.matches(
            #"ls | xargs rm -rf; find . -delete; echo x > a; kill -9 1; kubectl delete pod x --force; DROP TABLE y"#)
        XCTAssertEqual(found, ["rm -rf", "DROP", "--force", "kill -9", "kubectl delete", "> file", "find -delete", "xargs/piped rm"])
        XCTAssertEqual(found, found.sorted { StagingDestructivePatterns.names.firstIndex(of: $0)! < StagingDestructivePatterns.names.firstIndex(of: $1)! })

    }

    func testEveryNonASCIIScalarIsIsolatedFromTheTextBesideIt() {
        let label = StagingHazards.nonASCIILabel("\u{05D0}") ?? ""
        XCTAssertTrue(label.contains("\u{2068}\u{05D0}\u{2069} U+05D0"), label)
    }

    // MARK: History expansion (the cases of tests/fixtures/terminal_staging/hazards.json)

    func testHistoryExpansionRule() {
        let positives = ["!!", "!ssh", "!$", "!-2", "!#", "!ls -la", "echo hi !!", "^a^b", "^foo", "r", "fc -l", "history",
                         "history | grep x", "ls; r", "ls && fc", "ls || history", "ls | r 2",
                         // `fc` and `history` count as a word anywhere (S2 review): asking is the cheap side.
                         "grep history x", "rg fc"]
        for command in positives { XCTAssertTrue(StagingHazards.usesHistoryExpansion(command), command) }
        let negatives = ["[ a != b ]", "echo hi!", "echo ! x", "git status", "ls -r", "echo r", "echo !(x)",
                         "echo ^caret", "ls -la", "echo a!=b", "ls r"]
        for command in negatives { XCTAssertFalse(StagingHazards.usesHistoryExpansion(command), command) }
    }

    /// Every case in the file the daemon's tests read too: both sides must say the same.
    func testTheSharedFixtureGivesTheSameAnswerAsTheDaemon() throws {
        let cases = try StagingFixtures.hazards()
        XCTAssertGreaterThan(cases.count, 500, "hazards.json should be found")
        for entry in cases {
            let text = try XCTUnwrap(entry["text"] as? String)
            let expected = try XCTUnwrap(entry["history"] as? Bool)
            XCTAssertEqual(StagingHazards.usesHistoryExpansion(text), expected, "\(entry["name"] ?? "?"): \(text)")
        }
    }

    /// The fixture's optional `destructive` (pattern names) and `escape_quoted` (the `$'..\x..'` label) fields.
    func testTheSharedFixtureGivesTheExpectedDestructiveNamesAndEscapeQuoteLabel() throws {
        var checked = 0
        for entry in try StagingFixtures.hazards() {
            let text = try XCTUnwrap(entry["text"] as? String)
            let name = entry["name"] as? String ?? "?"
            if let names = entry["destructive"] as? [String] {
                XCTAssertEqual(StagingDestructivePatterns.matches(text), names, "\(name): \(text)")
                checked += 1
            }
            if let escaped = entry["escape_quoted"] as? Bool {
                XCTAssertEqual(StagingHazards.escapeQuotedWordLabel(text) != nil, escaped, "\(name): \(text)")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 100, "the fixture pins the destructive names of at least 100 rows")
    }

    func testEmptyExpansionsAreSeenThroughInBothForms() {
        XCTAssertEqual(StagingHazards.normalised("rm${IFS}-rf /"), "rm -rf /")
        XCTAssertEqual(StagingHazards.normalised("r$@m"), "r m")
        XCTAssertEqual(StagingHazards.normalised("r$@m", empty: ""), "rm")
        XCTAssertTrue(StagingDestructivePatterns.matches("rm${IFS}-rf /").contains("rm -rf"))
        XCTAssertTrue(StagingDestructivePatterns.matches("r$()m -rf /").contains("rm -rf"))
        XCTAssertTrue(StagingHazards.usesHistoryExpansion("X=1 r"))
        XCTAssertTrue(StagingHazards.usesHistoryExpansion("nice -n 5 r"))
        XCTAssertTrue(StagingHazards.usesHistoryExpansion("- r"))
    }

    // MARK: Non-ASCII

    func testALookAlikeLetterIsNamedWithItsCodePoint() {
        XCTAssertEqual(StagingHazards.nonASCIILabel("echo \u{0430}"),
                       "\u{26A0} Contains non-ASCII: \u{2068}\u{0430}\u{2069} U+0430 CYRILLIC SMALL LETTER A")
        XCTAssertNil(StagingHazards.nonASCIILabel("echo hello"))
    }

    func testAtMostThreeDistinctScalarsAreNamedThenAndNMore() {
        let label = StagingHazards.nonASCIILabel("\u{0430}\u{0430}\u{0431}\u{0432}\u{0433}\u{0434}") ?? ""
        XCTAssertTrue(label.contains("U+0430"), label)
        XCTAssertTrue(label.contains("U+0431"), label)
        XCTAssertTrue(label.contains("U+0432"), label)
        XCTAssertFalse(label.contains("U+0433"), label)
        XCTAssertTrue(label.hasSuffix("and 2 more"), label)
        XCTAssertEqual(label.components(separatedBy: "U+0430").count - 1, 1, "a repeated scalar is named once")
    }

    /// The shared fixture the daemon's tests read too: every case's `history` flag is what the app computes.
    func testTheSharedHazardsFixtureAgreesWithTheAppsHistoryRule() throws {
        let data = try StagingFixtures.fixtureData("hazards.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 500, "hazards.json should be found")
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            let text = try XCTUnwrap(entry["text"] as? String, name)
            let expected = try XCTUnwrap(entry["history"] as? Bool, name)
            XCTAssertEqual(StagingHazards.usesHistoryExpansion(text), expected, "\(name): \(text)")
        }
    }
}
