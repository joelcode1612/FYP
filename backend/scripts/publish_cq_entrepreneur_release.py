"""Operator publication of the entrepreneur-specific CQ release.

Read-only by default. ``--apply`` performs the whole publication in **one**
transaction, and prints the identities it created.

Why an operator script
----------------------
Publication is not a respondent action. ``p1_ee01_runtime`` holds SELECT only on
``cq_bank_versions`` / ``cq_manifest_releases`` / ``cq_question_assignments``;
the only policies there are SELECT policies. A respondent process must never be
able to mint the instrument it answers, so the release rows are written by the
operator principal and the runtime only ever reads them.

What it reuses
--------------
* ``services.cq_release_builder`` for construction, fingerprint, authorisation
  plan and the bank/release/assignment rows.
* ``project1.cq_entrepreneur_adapter`` for the authoritative comparison.
* ``domain.cq_runtime.verify_release`` for the structural gate.
* ``services.synthetic_execution_service.SyntheticExecutionService`` for the
  synthetic session (driven separately by ``--session``).

Nothing here invents wording, a stimulus, an approval or a feature bank.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from uuid import UUID, uuid4

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / 'src'))
sys.path.insert(0, str(BACKEND))

from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.cq_successor.preview_catalogue import (  # noqa: E402
    PreviewQuestionCatalogue, build_slot_values,
)
from sitewise.domain.customer_questionnaire import digest  # noqa: E402
from sitewise.project1 import cq_entrepreneur_adapter as adapter  # noqa: E402
from sitewise.services import cq_release_builder as builder  # noqa: E402
from sitewise.services.cq_synthetic_binding import record_campaign_binding  # noqa: E402
from sitewise.services.customer_questionnaire_candidate import (  # noqa: E402
    load_sources,
)

EXPECTED_DATABASE = 'project1_pg18_migrated_tests'
EXPECTED_PORT = 5544
FORBIDDEN_DATABASES = {'Dss', 'Final_Location_Analysis'}
FORBIDDEN_PORTS = {5432, 5433}

OPERATOR_URL = ('postgresql+psycopg2://postgres@127.0.0.1:5544/'
                'project1_pg18_migrated_tests')

ASSESSMENT_ID = 'df15adf3-be2c-4751-86aa-78fda663cf93'
BANK_VERSION = 'CQ-ENTREP-df15adf3-r23-cq-manifest-1'
RELEASE_VERSION = '1'
TITLE = 'Entrepreneur-specific questionnaire — Johor, RM 16.00'
CONSENT_VERSION = 'consent/1'
CONSENT_TEXT = 'Synthetic isolated test. No customer fielding.'
OPERATOR_RECEIPT = 'OWNER-AUTHORIZED-20261125-CONTROLLED-PUBLICATION'


def assert_target(connection) -> dict:
    row = connection.execute(text(
        'SELECT current_database(), inet_server_port(), current_user, '
        '       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)')).one()
    database, port, user, superuser = row
    if database != EXPECTED_DATABASE:
        raise SystemExit(f'REFUSED: database is {database!r}, not {EXPECTED_DATABASE!r}')
    if database in FORBIDDEN_DATABASES or port in FORBIDDEN_PORTS:
        raise SystemExit(f'REFUSED: protected target {database}@{port}')
    if port != EXPECTED_PORT:
        raise SystemExit(f'REFUSED: port is {port}, not {EXPECTED_PORT}')
    return {'database': database, 'port': port, 'user': user, 'superuser': superuser}


def authoritative(connection, actor_id: str) -> dict:
    """The records the release must agree with, read as the operator."""
    connection.execute(text("SELECT set_config('project1.actor_id', :a, true)"),
                       {'a': actor_id})
    assessment = connection.execute(text(
        'SELECT id, owner_user_id, revision, confirmed_revision FROM m2_assessments '
        'WHERE id = :id'), {'id': ASSESSMENT_ID}).mappings().one()
    if assessment['revision'] != assessment['confirmed_revision']:
        raise SystemExit('REFUSED: assessment revision is not confirmed')
    # DD-093 Option A: the build receipt names the authoritative context.
    #
    # This used to take ``ORDER BY assessment_revision DESC LIMIT 1``, which
    # breaks ties arbitrarily among the several PERSISTED rows a revision can
    # accumulate (retries, contract changes, deliberate re-builds). The release
    # manifest could therefore name a context the workflow never produced — for
    # example a 1.1.0 packet that carries no sections. The receipt is the record
    # of what the build actually wrote, so it is the authority. The fallback is
    # only for a confirmation built before the receipt table existed.
    context = connection.execute(text(
        'SELECT c.context_id, c.confirmation_id, c.assessment_revision, '
        '       c.packet_hash, c.concept_version, c.lifecycle_status, c.packet_json '
        'FROM m2_business_context_builds b '
        'JOIN m2_business_contexts c ON c.context_id = b.context_id '
        'WHERE b.assessment_id = :aid '
        '  AND b.assessment_revision = :rev '
        '  AND b.status = \'PERSISTED\' '
        '  AND c.assessment_id = :aid '
        '  AND c.lifecycle_status = \'PERSISTED\' '
        'LIMIT 1'),
        {'aid': ASSESSMENT_ID, 'rev': int(assessment['revision'])}).mappings().first()
    if context is None:
        context = connection.execute(text(
            'SELECT context_id, confirmation_id, assessment_revision, packet_hash, '
            '       concept_version, lifecycle_status, packet_json '
            'FROM m2_business_contexts WHERE assessment_id = :aid '
            'ORDER BY assessment_revision DESC, created_at DESC LIMIT 1'),
            {'aid': ASSESSMENT_ID}).mappings().one()
    if context['assessment_revision'] != assessment['revision']:
        raise SystemExit('REFUSED: business context is not at the confirmed revision')
    confirmation = connection.execute(text(
        'SELECT id, assessment_id, assessment_revision FROM m2_confirmation_snapshots '
        'WHERE id = :id'), {'id': context['confirmation_id']}).mappings().one()

    rows = connection.execute(text(
        "SELECT i.item_key, a.answer_state, a.value_json "
        "FROM m2_answer_revisions a JOIN m2_item_versions i ON i.id = a.item_version_id "
        "WHERE a.assessment_id = :aid AND i.item_key IN ('M2V2-01','M2V2-14') "
        "AND a.assessment_revision <= :rev ORDER BY a.assessment_revision DESC"),
        {'aid': ASSESSMENT_ID, 'rev': int(assessment['revision'])}).mappings().all()
    latest: dict[str, object] = {}
    for row in rows:
        latest.setdefault(row['item_key'], row)
    area, offer = latest.get('M2V2-01'), latest.get('M2V2-14')
    slots = build_slot_values(
        study_area=(area['value_json'] if area and area['answer_state'] == 'ANSWERED' else None),
        concept_version=context['concept_version'],
        priced_offer=(offer['value_json'] if offer and offer['answer_state'] == 'ANSWERED' else None),
    )
    return {
        'assessment': dict(assessment),
        'confirmation': dict(confirmation),
        'context': {k: v for k, v in dict(context).items() if k != 'packet_json'},
        'packet': context['packet_json'],
        'slot_values': slots,
    }


def compose(authoritative_records: dict, contract, policy) -> tuple[dict, dict, dict]:
    """Build the composition, the binding and the stimuli from the records."""
    slots = authoritative_records['slot_values']
    populated = PreviewQuestionCatalogue.load().populate(slots)
    items = [{
        'item_id': row.question.question_id,
        'stem': row.populated_stem,
        'stem_template': row.question.stem_template,
        'response_format': row.question.response_type,
        'population_status': row.population_status,
        'unresolved_slots': [{'slot': u.slot, 'required': u.required}
                             for u in row.unresolved],
    } for row in populated.questions]
    composed = {'items': items, 'declarations': {'slot_values': dict(slots)}}

    assessment = authoritative_records['assessment']
    context = authoritative_records['context']
    assignment = {
        'contract_version': adapter.ASSIGNMENT_CONTRACT,
        'assessment_id': str(assessment['id']),
        'assessment_revision': int(assessment['revision']),
        'confirmation_id': str(authoritative_records['confirmation']['id']),
        'bcb_context_id': str(context['context_id']),
        'bcb_packet_hash': str(context['packet_hash']),
        'template_versions': {q['id']: str(contract['spec_version'])
                              for q in contract['items']},
        'slot_values': dict(slots),
    }

    concept = (authoritative_records['packet'].get('concept') or {})
    stimuli = {
        # Both texts are deterministic renderings of owner-confirmed values:
        # the confirmed concept description, and the declared priced offer.
        'concept': {'version': str(context['concept_version']),
                    'text': {'EN': str((concept.get('content') or {}).get('description') or '')}},
        'offer': {'version': f"M2V2-14@r{assessment['revision']}",
                  'text': {'EN': f"{slots['product_spec']} at {slots['exact_rm_price']}"}},
    }
    return composed, assignment, stimuli


class OperatorUnit:
    """The slice of ``CqUnit`` that ``builder.publish`` needs, on an operator connection."""

    def __init__(self, connection):
        self.session = connection

    def _one(self, statement, params):
        row = self.session.execute(text(statement), params).mappings().first()
        return dict(row) if row else None

    def release_by_manifest_hash(self, value):
        return self._one('SELECT * FROM cq_manifest_releases WHERE manifest_hash = :h',
                         {'h': value})

    def bank(self, version):
        return self._one('SELECT * FROM cq_bank_versions WHERE version = :v', {'v': version})

    def assignments(self, release_id):
        return [dict(r) for r in self.session.execute(text(
            'SELECT * FROM cq_question_assignments WHERE release_id = :r'),
            {'r': str(release_id)}).mappings()]

    def insert_bank(self, **row):
        self.session.execute(text(
            'INSERT INTO cq_bank_versions(version, content_hash, questions_json) '
            'VALUES (:version, :content_hash, CAST(:questions AS jsonb))'),
            {'version': row['version'], 'content_hash': row['content_hash'],
             'questions': json.dumps(row['questions_json'])})

    def insert_release(self, **row):
        self.session.execute(text(
            'INSERT INTO cq_manifest_releases(id, manifest_hash, policy_hash, '
            'manifest_json, policy_json, source_class) VALUES (:id, :manifest_hash, '
            ':policy_hash, CAST(:manifest AS jsonb), CAST(:policy AS jsonb), :source_class)'),
            {'id': str(row['id']), 'manifest_hash': row['manifest_hash'],
             'policy_hash': row['policy_hash'],
             'manifest': json.dumps(row['manifest_json']),
             'policy': json.dumps(row['policy_json']),
             'source_class': row['source_class']})

    def insert_assignment(self, **row):
        self.session.execute(text(
            'INSERT INTO cq_question_assignments(release_id, slot_id, question_id, '
            'question_version, bank_version, content_hash) VALUES (:release_id, '
            ':slot_id, :question_id, :question_version, :bank_version, :content_hash)'),
            {**{k: row[k] for k in ('slot_id', 'question_id', 'question_version',
                                    'bank_version', 'content_hash')},
             'release_id': str(row['release_id'])})


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true',
                        help='write the release (default is read-only planning)')
    parser.add_argument('--campaign', action='store_true',
                        help='also create the campaign that makes the release visible')
    parser.add_argument('--session', action='store_true',
                        help='also create the campaign, participant and synthetic session')
    parser.add_argument('--use-existing-release', default='',
                        help='attach work to an already published release id '
                             'instead of republishing (DD-095)')
    parser.add_argument('--run-id', default='')
    parser.add_argument('--subject', default='')
    parser.add_argument('--output', default='')
    args = parser.parse_args(argv)

    contract, policy, reference = load_sources()
    engine = create_engine(OPERATOR_URL)

    with engine.connect() as connection:
        connection.execute(text('SET TRANSACTION READ ONLY'))
        target = assert_target(connection)
        records_actor = str(connection.execute(text(
            'SELECT owner_user_id FROM m2_assessments WHERE id = :i'),
            {'i': ASSESSMENT_ID}).scalar())
        records = authoritative(connection, records_actor)
        composed, assignment, stimuli = compose(records, contract, policy)
        manifest = builder.build_manifest(
            composed, contract=contract, policy=policy, assignment=assignment,
            stimuli=stimuli, bank_version=BANK_VERSION, version=RELEASE_VERSION,
            title=TITLE, consent_version=CONSENT_VERSION, consent_text=CONSENT_TEXT)
        plan = builder.plan(manifest, composed, contract, policy)

    print('=== target ===')
    print(' ', target)
    print('=== binding ===')
    print('  assessment   :', records['assessment']['id'], 'rev',
          records['assessment']['revision'],
          'confirmed', records['assessment']['confirmed_revision'])
    print('  confirmation :', records['confirmation']['id'])
    print('  context      :', records['context']['context_id'])
    print('  packet_hash  :', records['context']['packet_hash'])
    print('  context_ver  :', (records['packet'] or {}).get('context_version'))
    print('  slots        :', json.dumps(records['slot_values'], ensure_ascii=False))
    print('=== plan ===')
    print('  manifest_hash:', plan['manifest_hash'])
    print('  label_fp     :', plan['label_fingerprint'])
    print('  stimuli      :', plan['stimuli'])
    print('  authorized   :', plan['authorized_count'], '/', plan['question_count'])
    for row in plan['questions']:
        mark = 'ASK' if row['authorized'] else '---'
        print(f"  {mark} {row['question_id']} opts={row['option_count']:2d} "
              f"{row['gate']:52s} {','.join(row['reasons'])}")

    result: dict[str, object] = {'target': target, 'plan': plan,
                                 'manifest': manifest, 'binding': {
                                     k: records[k] for k in
                                     ('assessment', 'confirmation', 'context',
                                      'slot_values')}}
    if not args.apply:
        print('\nREAD-ONLY: nothing written. Re-run with --apply to publish.')
    else:
        plan_sha = digest(plan)
        with engine.begin() as connection:
            unit = OperatorUnit(connection)
            if args.use_existing_release:
                # Attach work to the release that is already published instead of
                # republishing it. `--apply` rebuilds the manifest from the
                # *current* BCB context, which is a different manifest and
                # therefore a different content-addressed release id, so the
                # campaign guard refuses and the whole transaction rolls back
                # (DD-095). Reusing the stored row is the only way to bind a
                # session to it without a supersession migration.
                row = connection.execute(text(
                    'SELECT * FROM cq_manifest_releases WHERE id = :id'),
                    {'id': args.use_existing_release}).mappings().first()
                if row is None:
                    raise SystemExit(
                        f'REFUSED: release {args.use_existing_release} does not exist')
                assignments = [dict(r) for r in connection.execute(text(
                    'SELECT * FROM cq_question_assignments WHERE release_id = :id'),
                    {'id': args.use_existing_release}).mappings()]
                if not assignments:
                    raise SystemExit('REFUSED: release has no assignments')
                manifest = row['manifest_json']
                policy = row['policy_json']
                published = {'state': 'ALREADY_PUBLISHED', 'release': dict(row),
                             'assignments': assignments,
                             'manifest_hash': row['manifest_hash']}
                # Pin what was actually published, rather than a plan recomputed
                # from a manifest that is not the published one.
                plan_sha = digest({
                    'manifest_hash': row['manifest_hash'],
                    'authorized_question_ids': manifest['authorized_question_ids'],
                    'assignments': sorted((a['slot_id'], a['content_hash'])
                                          for a in assignments)})
                result['manifest'] = manifest
            else:
                published = builder.publish(
                    unit, manifest, policy, contract=contract, reference=reference,
                    actor_id=records_actor, source_class='SYNTHETIC_FIXTURE',
                    templates=adapter.governed_templates())
            release_id = published['release']['id']
            result['publication'] = {
                'state': published['state'],
                'release_id': str(release_id),
                'manifest_hash': published['manifest_hash'],
                'bank_version': published['release'].get('manifest_json', {}).get(
                    'bank_version', manifest['bank_version']),
                'assignments': len(published['assignments']),
            }
            print('\n=== publication ===')
            print('  state        :', published['state'])
            print('  release_id   :', release_id)
            print('  manifest_hash:', published['manifest_hash'])
            print('  assignments  :', len(published['assignments']))

            if args.campaign or args.session:
                # A release is only visible to the runtime through a campaign
                # (`cq_manifest_releases` SELECT is `id IN (SELECT release_id
                # FROM cq_campaigns)`), so the campaign is part of publication.
                campaign = connection.execute(text(
                    'INSERT INTO cq_campaigns(id, assessment_id, owner_user_id, release_id) '
                    'VALUES (:id, :aid, :owner, :release) '
                    'ON CONFLICT (assessment_id) DO NOTHING '
                    'RETURNING id, assessment_id, owner_user_id, release_id'),
                    {'id': str(uuid4()), 'aid': ASSESSMENT_ID,
                     'owner': records_actor, 'release': str(release_id)}).mappings().first()
                if campaign is None:
                    # One campaign per assessment (`UNIQUE(assessment_id)`), so a
                    # republish reuses the campaign that already exists. A campaign
                    # pointing at a *different* release is refused, not adopted.
                    campaign = connection.execute(text(
                        'SELECT id, assessment_id, owner_user_id, release_id FROM '
                        'cq_campaigns WHERE assessment_id = :aid'),
                        {'aid': ASSESSMENT_ID}).mappings().one()
                    if str(campaign['release_id']) != str(release_id):
                        raise SystemExit('REFUSED: assessment already has a campaign '
                                         'bound to a different release')
                result['campaign'] = {k: str(v) for k, v in dict(campaign).items()}
                print('=== campaign ===')
                print('  campaign_id  :', campaign['id'])
                print('  assessment   :', campaign['assessment_id'])
                print('  release_id   :', campaign['release_id'])

            if args.session:
                if not args.run_id:
                    raise SystemExit('--session requires --run-id')
                subject = args.subject or records_actor
                connection.execute(text(
                    'INSERT INTO cq_participants(campaign_id, respondent_user_id) '
                    'VALUES (:c, :r) ON CONFLICT DO NOTHING'),
                    {'c': str(campaign['id']), 'r': subject})
                session = connection.execute(text(
                    'INSERT INTO cq_sessions(id, campaign_id, release_id, respondent_user_id, '
                    'locale, revision, state, consented, consent_version) '
                    "VALUES (:id, :c, :release, :r, 'EN', 0, 'ACTIVE', false, NULL) "
                    'RETURNING id, revision, state'),
                    {'id': str(uuid4()), 'c': str(campaign['id']),
                     'release': str(release_id), 'r': subject}).mappings().one()

                control = {
                    'scenario': 'NORMAL',
                    'source_class': 'SYNTHETIC_FIXTURE',
                    'synthetic_run_id': args.run_id,
                    'consent_semantics': 'SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT',
                    'session_id': str(session['id']),
                    'assessment_id': ASSESSMENT_ID,
                    'campaign_id': str(campaign['id']),
                    'owner_user_id': records_actor,
                    'respondent_user_id': subject,
                    'release_id': str(release_id),
                    'manifest_hash': published['manifest_hash'],
                    'instrument_version': manifest['spec_version'],
                    'bank_version': manifest['bank_version'],
                    'routing_version': manifest['policy_version'],
                    'consent_version': manifest['consent_version'],
                    'consent_hash': digest(manifest['consent_text']['EN']),
                }
                connection.execute(text(
                    'INSERT INTO cq_session_controls(session_id, research_mode, eligibility, '
                    'qualification_version, source_json, source_hash) VALUES (:s, '
                    "'DEVELOPER_PREVIEW', 'ELIGIBLE', :q, CAST(:j AS jsonb), :h)"),
                    {'s': str(session['id']), 'q': 'SYNTHETIC-DEVELOPER-PREVIEW-1',
                     'j': json.dumps(control), 'h': digest(control)})
                case = dict(control)
                # The run registry (`cq_synthetic_import_runs`) is the FK parent of
                # every synthetic case. It records *what* the run was made from, so
                # the two hashes are the real artifacts: the published manifest and
                # the authorisation plan. No DSS package is claimed.
                connection.execute(text(
                    'INSERT INTO cq_synthetic_import_runs(run_id, owner_user_id, '
                    'package_sha256, plan_sha256, origin, effective_mode, '
                    'consent_semantics, real_reportable, operator_receipt, manifest_json) '
                    "VALUES (:run, :owner, :pkg, :plan, 'SYNTHETIC_TEST', "
                    "'DEVELOPER_PREVIEW', 'SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT', "
                    'false, :receipt, CAST(:j AS jsonb)) ON CONFLICT DO NOTHING'),
                    {'run': args.run_id, 'owner': records_actor,
                     'pkg': published['manifest_hash'], 'plan': plan_sha,
                     'receipt': OPERATOR_RECEIPT,
                     'j': json.dumps({'contract_version': 'cq-publication-run/1',
                                      'release_id': str(release_id),
                                      'manifest_hash': published['manifest_hash'],
                                      'authorized_question_ids':
                                          manifest['authorized_question_ids'],
                                      'source_class': 'SYNTHETIC_FIXTURE'})})
                connection.execute(text(
                    'INSERT INTO cq_synthetic_cases(session_id, run_id, case_key, scenario, '
                    'source_json, source_sha256, origin, real_reportable) VALUES (:s, :run, '
                    ":key, 'NORMAL', CAST(:j AS jsonb), :h, 'SYNTHETIC_TEST', false)"),
                    {'s': str(session['id']), 'run': args.run_id,
                     'key': 'entrepreneur-df15adf3-r23', 'j': json.dumps(case),
                     'h': digest(case)})
                # The campaign -> run binding is what lets EE-01 resolve a campaign
                # back to the run that produced it (`boundary_run`). Without it the
                # run is unreachable, `synthetic` is None, and every measurement is
                # Q=0 (DD-106). Recorded as a developer action, never a package.
                binding = record_campaign_binding(
                    connection, run_id=args.run_id, campaign=campaign,
                    release_id=release_id, manifest_hash=published['manifest_hash'])
                # `cq_synthetic_execution_grants` has a composite foreign key to
                # `cq_synthetic_preview_grants(run_id, developer_user_id)`, so the
                # preview grant has to exist first. Omitting it made this whole
                # block fail with a ForeignKeyViolation and roll back, which is
                # why `--session` had never produced a session.
                connection.execute(text(
                    'INSERT INTO cq_synthetic_preview_grants(run_id, developer_user_id, '
                    'principal_source, profile_anchor_sha256, may_pause_resume, '
                    'operator_receipt) VALUES (:run, :dev, :src, :anchor, true, :receipt) '
                    'ON CONFLICT DO NOTHING'),
                    {'run': args.run_id, 'dev': records_actor,
                     'src': 'EXISTING_VERIFIED_APP_PROFILE', 'anchor': digest(case),
                     'receipt': OPERATOR_RECEIPT})
                connection.execute(text(
                    'INSERT INTO cq_synthetic_execution_grants(run_id, developer_user_id, '
                    'operator_receipt) VALUES (:run, :dev, :receipt)'),
                    {'run': args.run_id, 'dev': records_actor,
                     'receipt': OPERATOR_RECEIPT})
                result['session'] = {
                    'campaign_id': str(campaign['id']),
                    'session_id': str(session['id']),
                    'run_id': args.run_id,
                    'subject': subject,
                }
                print('=== session ===')
                print('  campaign_id  :', campaign['id'])
                print('  session_id   :', session['id'])
                print('  run_id       :', args.run_id)
                print('  subject      :', subject)

    if args.output:
        Path(args.output).write_text(
            json.dumps(result, indent=1, default=str), encoding='utf-8')
        print('\nwrote', args.output)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
