(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-UNAUTHORIZED (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-ALREADY-EXISTS (err u104))
(define-constant ERR-PROJECT-CLOSED (err u105))
(define-constant ERR-INVALID-STATUS (err u106))
(define-constant ERR-INSUFFICIENT-STAKE (err u107))
(define-constant ERR-DEADLINE-PASSED (err u108))
(define-constant ERR-NOT-COLLABORATOR (err u109))
(define-constant ERR-IP-PROTECTED (err u110))

(define-data-var next-project-id uint u0)
(define-data-var next-proposal-id uint u0)
(define-data-var platform-fee-rate uint u300)
(define-data-var min-project-stake uint u1000000)
(define-data-var collaboration-bonus uint u100)
(define-data-var ip-protection-period uint u52560)

(define-map innovation-projects
    { project-id: uint }
    {
        creator: principal,
        title: (string-ascii 100),
        description: (string-ascii 500),
        total-funding: uint,
        current-funding: uint,
        deadline: uint,
        status: (string-ascii 20),
        collaboration-count: uint,
        ip-hash: (optional (buff 32)),
        created-at: uint,
        category: (string-ascii 50)
    }
)

(define-map project-collaborators
    { project-id: uint, collaborator: principal }
    {
        contribution-weight: uint,
        joined-at: uint,
        reward-claimed: bool,
        contribution-hash: (optional (buff 32))
    }
)

(define-map innovation-proposals
    { proposal-id: uint }
    {
        project-id: uint,
        proposer: principal,
        title: (string-ascii 100),
        description: (string-ascii 500),
        implementation-plan: (string-ascii 1000),
        requested-funding: uint,
        votes-for: uint,
        votes-against: uint,
        status: (string-ascii 20),
        created-at: uint
    }
)

(define-map proposal-votes
    { proposal-id: uint, voter: principal }
    { vote: bool, weight: uint }
)

(define-map innovator-profiles
    { innovator: principal }
    {
        reputation: uint,
        projects-created: uint,
        collaborations: uint,
        proposals-submitted: uint,
        total-earned: uint,
        ip-contributions: uint
    }
)

(define-map project-funding
    { project-id: uint, funder: principal }
    { amount: uint, funded-at: uint }
)

(define-map ip-registry
    { ip-hash: (buff 32) }
    {
        owner: principal,
        project-id: uint,
        protection-expires: uint,
        license-terms: (string-ascii 200)
    }
)

(define-map innovation-categories
    { category-name: (string-ascii 50) }
    { active: bool, project-count: uint }
)

(define-private (get-project-or-fail (project-id uint))
    (ok (unwrap! (map-get? innovation-projects { project-id: project-id }) ERR-NOT-FOUND))
)

(define-private (get-proposal-or-fail (proposal-id uint))
    (ok (unwrap! (map-get? innovation-proposals { proposal-id: proposal-id }) ERR-NOT-FOUND))
)

(define-private (is-project-active (project-id uint))
    (let ((project (unwrap! (map-get? innovation-projects { project-id: project-id }) false)))
        (and 
            (is-eq (get status project) "active")
            (< stacks-block-height (get deadline project))
        )
    )
)

(define-private (calculate-platform-fee (amount uint))
    (/ (* amount (var-get platform-fee-rate)) u10000)
)

(define-private (update-innovator-stats (innovator principal) (action (string-ascii 20)))
    (let ((profile (default-to
            { reputation: u0, projects-created: u0, collaborations: u0, proposals-submitted: u0, total-earned: u0, ip-contributions: u0 }
            (map-get? innovator-profiles { innovator: innovator })
        )))
        (if (is-eq action "create-project")
            (map-set innovator-profiles
                { innovator: innovator }
                (merge profile { 
                    projects-created: (+ (get projects-created profile) u1),
                    reputation: (+ (get reputation profile) u50)
                })
            )
            (if (is-eq action "join-collaboration")
                (map-set innovator-profiles
                    { innovator: innovator }
                    (merge profile { 
                        collaborations: (+ (get collaborations profile) u1),
                        reputation: (+ (get reputation profile) u20)
                    })
                )
                (if (is-eq action "submit-proposal")
                    (map-set innovator-profiles
                        { innovator: innovator }
                        (merge profile { 
                            proposals-submitted: (+ (get proposals-submitted profile) u1),
                            reputation: (+ (get reputation profile) u10)
                        })
                    )
                    (if (is-eq action "register-ip")
                        (map-set innovator-profiles
                            { innovator: innovator }
                            (merge profile { 
                                ip-contributions: (+ (get ip-contributions profile) u1),
                                reputation: (+ (get reputation profile) u75)
                            })
                        )
                        true
                    )
                )
            )
        )
    )
)

(define-private (update-category-stats (category (string-ascii 50)))
    (let ((category-info (default-to { active: true, project-count: u0 } (map-get? innovation-categories { category-name: category }))))
        (map-set innovation-categories
            { category-name: category }
            (merge category-info { project-count: (+ (get project-count category-info) u1) })
        )
    )
)

(define-public (create-innovation-project (title (string-ascii 100)) (description (string-ascii 500)) (funding-goal uint) (deadline-blocks uint) (category (string-ascii 50)))
    (let (
        (project-id (var-get next-project-id))
        (initial-stake (stx-get-balance tx-sender))
        (platform-fee (calculate-platform-fee initial-stake))
        (net-stake (- initial-stake platform-fee))
    )
        (asserts! (>= initial-stake (var-get min-project-stake)) ERR-INSUFFICIENT-STAKE)
        (asserts! (> deadline-blocks stacks-block-height) ERR-DEADLINE-PASSED)
        (try! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER))
        (try! (stx-transfer? net-stake tx-sender (as-contract tx-sender)))
        (var-set next-project-id (+ project-id u1))
        (map-set innovation-projects
            { project-id: project-id }
            {
                creator: tx-sender,
                title: title,
                description: description,
                total-funding: funding-goal,
                current-funding: net-stake,
                deadline: deadline-blocks,
                status: "active",
                collaboration-count: u0,
                ip-hash: none,
                created-at: stacks-block-height,
                category: category
            }
        )
        (update-innovator-stats tx-sender "create-project")
        (update-category-stats category)
        (ok project-id)
    )
)

(define-public (join-collaboration (project-id uint) (contribution-weight uint))
    (let ((project (try! (get-project-or-fail project-id))))
        (asserts! (is-project-active project-id) ERR-PROJECT-CLOSED)
        (asserts! (> contribution-weight u0) ERR-INVALID-AMOUNT)
        (asserts! (is-none (map-get? project-collaborators { project-id: project-id, collaborator: tx-sender })) ERR-ALREADY-EXISTS)
        (map-set project-collaborators
            { project-id: project-id, collaborator: tx-sender }
            {
                contribution-weight: contribution-weight,
                joined-at: stacks-block-height,
                reward-claimed: false,
                contribution-hash: none
            }
        )
        (map-set innovation-projects
            { project-id: project-id }
            (merge project { collaboration-count: (+ (get collaboration-count project) u1) })
        )
        (update-innovator-stats tx-sender "join-collaboration")
        (ok true)
    )
)

(define-public (submit-innovation-proposal (project-id uint) (title (string-ascii 100)) (description (string-ascii 500)) (implementation-plan (string-ascii 1000)) (requested-funding uint))
    (let (
        (project (try! (get-project-or-fail project-id)))
        (proposal-id (var-get next-proposal-id))
    )
        (asserts! (is-project-active project-id) ERR-PROJECT-CLOSED)
        (asserts! (> requested-funding u0) ERR-INVALID-AMOUNT)
        (var-set next-proposal-id (+ proposal-id u1))
        (map-set innovation-proposals
            { proposal-id: proposal-id }
            {
                project-id: project-id,
                proposer: tx-sender,
                title: title,
                description: description,
                implementation-plan: implementation-plan,
                requested-funding: requested-funding,
                votes-for: u0,
                votes-against: u0,
                status: "pending",
                created-at: stacks-block-height
            }
        )
        (update-innovator-stats tx-sender "submit-proposal")
        (ok proposal-id)
    )
)

(define-public (vote-on-proposal (proposal-id uint) (vote bool) (weight uint))
    (let ((proposal (try! (get-proposal-or-fail proposal-id))))
        (asserts! (is-eq (get status proposal) "pending") ERR-INVALID-STATUS)
        (asserts! (> weight u0) ERR-INVALID-AMOUNT)
        (asserts! (is-none (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender })) ERR-ALREADY-EXISTS)
        (map-set proposal-votes { proposal-id: proposal-id, voter: tx-sender } { vote: vote, weight: weight })
        (if vote
            (map-set innovation-proposals
                { proposal-id: proposal-id }
                (merge proposal { votes-for: (+ (get votes-for proposal) weight) })
            )
            (map-set innovation-proposals
                { proposal-id: proposal-id }
                (merge proposal { votes-against: (+ (get votes-against proposal) weight) })
            )
        )
        (ok true)
    )
)

(define-public (fund-project (project-id uint))
    (let (
        (project (try! (get-project-or-fail project-id)))
        (funding-amount (stx-get-balance tx-sender))
        (platform-fee (calculate-platform-fee funding-amount))
        (net-funding (- funding-amount platform-fee))
    )
        (asserts! (is-project-active project-id) ERR-PROJECT-CLOSED)
        (asserts! (> funding-amount u0) ERR-INVALID-AMOUNT)
        (try! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER))
        (try! (stx-transfer? net-funding tx-sender (as-contract tx-sender)))
        (map-set project-funding
            { project-id: project-id, funder: tx-sender }
            { amount: funding-amount, funded-at: stacks-block-height }
        )
        (map-set innovation-projects
            { project-id: project-id }
            (merge project { current-funding: (+ (get current-funding project) net-funding) })
        )
        (ok true)
    )
)

(define-public (register-ip (project-id uint) (ip-hash (buff 32)) (license-terms (string-ascii 200)))
    (let ((project (try! (get-project-or-fail project-id))))
        (asserts! (is-eq tx-sender (get creator project)) ERR-UNAUTHORIZED)
        (asserts! (is-none (map-get? ip-registry { ip-hash: ip-hash })) ERR-ALREADY-EXISTS)
        (map-set ip-registry
            { ip-hash: ip-hash }
            {
                owner: tx-sender,
                project-id: project-id,
                protection-expires: (+ stacks-block-height (var-get ip-protection-period)),
                license-terms: license-terms
            }
        )
        (map-set innovation-projects
            { project-id: project-id }
            (merge project { ip-hash: (some ip-hash) })
        )
        (update-innovator-stats tx-sender "register-ip")
        (ok true)
    )
)

(define-public (distribute-rewards (project-id uint))
    (let ((project (try! (get-project-or-fail project-id))))
        (asserts! (is-eq tx-sender (get creator project)) ERR-UNAUTHORIZED)
        (asserts! (or 
            (>= stacks-block-height (get deadline project))
            (>= (get current-funding project) (get total-funding project))
        ) ERR-INVALID-STATUS)
        (map-set innovation-projects
            { project-id: project-id }
            (merge project { status: "completed" })
        )
        (ok true)
    )
)

(define-public (claim-collaboration-reward (project-id uint))
    (let (
        (project (try! (get-project-or-fail project-id)))
        (collaboration (unwrap! (map-get? project-collaborators { project-id: project-id, collaborator: tx-sender }) ERR-NOT-COLLABORATOR))
    )
        (asserts! (is-eq (get status project) "completed") ERR-INVALID-STATUS)
        (asserts! (not (get reward-claimed collaboration)) ERR-ALREADY-EXISTS)
        (let (
            (total-reward (get current-funding project))
            (collaboration-reward (/ (* total-reward (get contribution-weight collaboration)) u100))
        )
            (try! (as-contract (stx-transfer? collaboration-reward tx-sender tx-sender)))
            (map-set project-collaborators
                { project-id: project-id, collaborator: tx-sender }
                (merge collaboration { reward-claimed: true })
            )
            (let ((profile (default-to
                    { reputation: u0, projects-created: u0, collaborations: u0, proposals-submitted: u0, total-earned: u0, ip-contributions: u0 }
                    (map-get? innovator-profiles { innovator: tx-sender })
                )))
                (map-set innovator-profiles
                    { innovator: tx-sender }
                    (merge profile { total-earned: (+ (get total-earned profile) collaboration-reward) })
                )
            )
            (ok collaboration-reward)
        )
    )
)

(define-public (update-platform-settings (fee-rate uint) (min-stake uint) (collab-bonus uint) (ip-period uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set platform-fee-rate fee-rate)
        (var-set min-project-stake min-stake)
        (var-set collaboration-bonus collab-bonus)
        (var-set ip-protection-period ip-period)
        (ok true)
    )
)

(define-read-only (get-project (project-id uint))
    (map-get? innovation-projects { project-id: project-id })
)

(define-read-only (get-proposal (proposal-id uint))
    (map-get? innovation-proposals { proposal-id: proposal-id })
)

(define-read-only (get-innovator-profile (innovator principal))
    (map-get? innovator-profiles { innovator: innovator })
)

(define-read-only (get-collaboration (project-id uint) (collaborator principal))
    (map-get? project-collaborators { project-id: project-id, collaborator: collaborator })
)

(define-read-only (get-ip-info (ip-hash (buff 32)))
    (map-get? ip-registry { ip-hash: ip-hash })
)

(define-read-only (get-project-funding (project-id uint) (funder principal))
    (map-get? project-funding { project-id: project-id, funder: funder })
)

(define-read-only (get-platform-stats)
    {
        total-projects: (var-get next-project-id),
        total-proposals: (var-get next-proposal-id),
        platform-fee-rate: (var-get platform-fee-rate),
        min-project-stake: (var-get min-project-stake),
        collaboration-bonus: (var-get collaboration-bonus),
        ip-protection-period: (var-get ip-protection-period)
    }
)

(define-read-only (get-category-info (category (string-ascii 50)))
    (map-get? innovation-categories { category-name: category })
)