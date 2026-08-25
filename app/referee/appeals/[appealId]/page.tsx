import { RefereeAppealDetail } from '@/components/referee-appeal-detail';

export default async function RefereeAppealPage({
  params,
}: {
  params: Promise<{ appealId: string }>;
}) {
  const { appealId } = await params;
  return <RefereeAppealDetail appealId={appealId} />;
}
